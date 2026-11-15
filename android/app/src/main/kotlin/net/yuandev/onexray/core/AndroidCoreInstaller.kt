package net.yuandev.onexray.core

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipFile

/**
 * Publishes the native library of an installed Android core release.
 *
 * The library is written read-only, because Android asks dynamically loaded
 * code to be immutable. The file is created first, locked read-only while it
 * is still open, and only then filled, so it is never writable after it is
 * published.
 */
object AndroidCoreInstaller {
    private const val TAG = "OneXrayCore"
    /**
     * Extracts the native library for [abi] from an installed core archive
     * and publishes it under the version directory.
     *
     * Returns the path of the published library relative to the app files
     * directory, or null when the archive does not carry that ABI.
     */
    fun publish(
        context: Context,
        aarPath: String,
        abi: String,
        installationId: String,
    ): String? {
        val archive = File(aarPath)
        if (!archive.isFile) return null
        val entryName = "jni/$abi/libgojni.so"
        val libraryBytes = readLibrary(archive, entryName) ?: return null
        val files = context.applicationContext.filesDir
        val directory = File(files, "core/versions/$installationId/android/$abi")
        if (!directory.exists() && !directory.mkdirs()) return null
        val target = File(directory, "libgojni.so")
        return try {
            val stream = FileOutputStream(target)
            try {
                // The descriptor stays writable, the file itself never is.
                target.setReadOnly()
                stream.write(libraryBytes)
                stream.fd.sync()
            } finally {
                stream.close()
            }
            target.absolutePath.removePrefix(files.absolutePath).removePrefix("/")
        } catch (error: Exception) {
            android.util.Log.w(TAG, "Unable to publish the core library", error)
            target.delete()
            null
        }
    }

    private fun readLibrary(archive: File, entryName: String): ByteArray? {
        val aar = runCatching { ZipFile(archive) }.getOrNull() ?: return null
        aar.use { inner ->
            val entry = inner.getEntry(entryName) ?: return null
            return inner.getInputStream(entry).use { it.readBytes() }
        }
    }
}
