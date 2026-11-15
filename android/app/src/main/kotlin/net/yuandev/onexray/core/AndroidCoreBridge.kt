package net.yuandev.onexray.core

import android.content.Context
import android.util.Log
import dalvik.system.DelegateLastClassLoader
import java.io.File
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import org.json.JSONObject

/** The App side of the fd protection callback the Core calls back into. */
interface CoreDialerController {
    fun protectFd(fd: Long): Boolean
}

/** The App side of the per-app connection lookup the Core can call. */
interface CoreProcessFinder {
    fun findProcessByConnection(
        network: String,
        srcIp: String,
        srcPort: Long,
        destIp: String,
        destPort: Long,
    ): Long
}

/**
 * Access to the libXray runtime.
 *
 * The App never links the generated gomobile classes directly: the runtime
 * either comes from the bundled archive or from a version the user
 * installed, and the classes of an installed archive have to be loaded by a
 * class loader that searches the native library directory of that version.
 * Every call therefore goes through reflection, and the callbacks the Core
 * makes into Java are served by a proxy built for the loaded interface.
 */
class AndroidCoreBridge internal constructor(
    private val invokeMethod: Method,
    private val setDnsMethod: Method,
    private val resetDnsMethod: Method,
    private val registerDialerMethod: Method,
    private val registerListenerMethod: Method,
    private val registerProcessFinderMethod: Method,
    private val dialerInterface: Class<*>,
    private val processFinderInterface: Class<*>,
    val source: String,
    val libraryPath: String?,
) {
    fun invoke(requestJson: String): String =
        invokeMethod.invoke(null, requestJson) as String

    fun setDns(controller: CoreDialerController, server: String) {
        setDnsMethod.invoke(null, proxy(dialerInterface) { _, args ->
            controller.protectFd((args?.get(0) as? Number)?.toLong() ?: 0L)
        }, server)
    }

    fun resetDns() {
        resetDnsMethod.invoke(null)
    }

    fun registerDialerController(controller: CoreDialerController) {
        registerDialerMethod.invoke(null, proxy(dialerInterface) { _, args ->
            controller.protectFd((args?.get(0) as? Number)?.toLong() ?: 0L)
        })
    }

    fun registerListenerController(controller: CoreDialerController) {
        registerListenerMethod.invoke(null, proxy(dialerInterface) { _, args ->
            controller.protectFd((args?.get(0) as? Number)?.toLong() ?: 0L)
        })
    }

    fun registerProcessFinder(finder: CoreProcessFinder?) {
        if (finder == null) {
            registerProcessFinderMethod.invoke(null, null)
            return
        }
        val proxy = proxy(processFinderInterface) { _, args ->
            finder.findProcessByConnection(
                args?.get(0) as? String ?: "",
                args?.get(1) as? String ?: "",
                (args?.get(2) as? Number)?.toLong() ?: 0L,
                args?.get(3) as? String ?: "",
                (args?.get(4) as? Number)?.toLong() ?: 0L,
            )
        }
        registerProcessFinderMethod.invoke(null, proxy)
    }

    /**
     * Builds a proxy for an interface the Core owns. The Core compares and
     * prints the callback objects, so identity and a stable name are kept.
     */
    private fun proxy(
        interfaceType: Class<*>,
        call: (Method, Array<Any?>?) -> Any?,
    ): Any {
        val holder = arrayOfNulls<Any>(1)
        val proxy = Proxy.newProxyInstance(
            interfaceType.classLoader,
            arrayOf(interfaceType),
            InvocationHandler { _, method, args ->
                when (method.name) {
                    "toString" -> "OneXrayCoreCallback"
                    "hashCode" -> System.identityHashCode(holder[0])
                    "equals" -> holder[0] === args?.get(0)
                    else -> call(method, args)
                }
            },
        )
        holder[0] = proxy
        return proxy
    }

    /** Describes the loaded runtime for the diagnostics screen. */
    fun runtimeInfo(): String {
        val info = JSONObject()
        info.put("source", source)
        info.put("libraryPath", libraryPath ?: "")
        info.put("pid", android.os.Process.myPid())
        return info.toString()
    }
}

/**
 * Builds the bridge for the current process.
 *
 * The selected runtime is announced by the Dart side in
 * `filesDir/core/selection.json`. When it names an installed library, the
 * classes are loaded by a class loader whose native library path is that
 * version, so the bundled library is never loaded in this process.
 */
object AndroidCoreBridgeProvider {
    private const val TAG = "OneXrayCore"
    private const val SELECTION_FILE = "core/selection.json"
    private const val RUNTIME_INFO_FILE = "core/loaded-core.json"

    @Volatile
    private var bridge: AndroidCoreBridge? = null

    @Synchronized
    fun initialize(context: Context): AndroidCoreBridge {
        bridge?.let { return it }
        val application = context.applicationContext
        val selection = readSelection(application)
        val libraryPath = selection?.optString("libraryPath")?.takeIf { it.isNotEmpty() }
        val libraryFile = libraryPath?.let { File(application.filesDir, it) }
        val loader = if (libraryFile != null && libraryFile.isFile) {
            runCatching { createLoader(application, libraryFile.parentFile!!) }
                .onFailure { Log.w(TAG, "Unable to build the core class loader", it) }
                .getOrNull()
        } else {
            null
        }
        val effectiveLibrary = if (loader != null) libraryFile else null
        val created = createBridge(
            loader ?: application.classLoader,
            if (effectiveLibrary != null) "downloaded" else "bundled",
            effectiveLibrary?.absolutePath,
        )
        bridge = created
        writeRuntimeInfo(application, created)
        return created
    }

    fun instance(): AndroidCoreBridge =
        bridge ?: throw IllegalStateException("The Core bridge is not initialized")

    fun runtimeInfo(context: Context): String {
        bridge?.let { return it.runtimeInfo() }
        val file = File(context.applicationContext.filesDir, RUNTIME_INFO_FILE)
        return if (file.isFile) file.readText() else "{}"
    }

    private fun createLoader(context: Context, libraryDirectory: File): ClassLoader {
        val dexPaths = ArrayList<String>()
        val applicationInfo = context.applicationContext.applicationInfo
        applicationInfo.sourceDir?.let { dexPaths.add(it) }
        applicationInfo.splitSourceDirs?.let { dexPaths.addAll(it) }
        return DelegateLastClassLoader(
            dexPaths.joinToString(":"),
            libraryDirectory.absolutePath,
            context.applicationContext.classLoader,
        )
    }

    private fun createBridge(
        loader: ClassLoader,
        source: String,
        libraryPath: String?,
    ): AndroidCoreBridge {
        val libXray = Class.forName("libXray.LibXray", true, loader)
        val dialer = Class.forName("libXray.DialerController", true, loader)
        val finder = Class.forName("libXray.ProcessFinder", true, loader)
        return AndroidCoreBridge(
            invokeMethod = libXray.getMethod("invoke", String::class.java),
            setDnsMethod = libXray.getMethod(
                "setDNS",
                dialer,
                String::class.java,
            ),
            resetDnsMethod = libXray.getMethod("resetDNS"),
            registerDialerMethod = libXray.getMethod("registerDialerController", dialer),
            registerListenerMethod = libXray.getMethod("registerListenerController", dialer),
            registerProcessFinderMethod = libXray.getMethod("registerProcessFinder", finder),
            dialerInterface = dialer,
            processFinderInterface = finder,
            source = source,
            libraryPath = libraryPath,
        )
    }

    private fun readSelection(context: Context): JSONObject? {
        val file = File(context.applicationContext.filesDir, SELECTION_FILE)
        if (!file.isFile) return null
        return runCatching { JSONObject(file.readText()) }.getOrNull()
    }

    private fun writeRuntimeInfo(context: Context, created: AndroidCoreBridge) {
        val file = File(context.applicationContext.filesDir, RUNTIME_INFO_FILE)
        runCatching {
            file.parentFile?.mkdirs()
            file.writeText(created.runtimeInfo())
        }
    }
}
