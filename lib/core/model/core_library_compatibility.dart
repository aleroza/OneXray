import 'package:onexray/core/ffi/elf_dynamic_symbols.dart';
import 'package:onexray/core/tools/core_platform.dart';

/// How a downloaded core library relates to the App's expectations.
enum CoreLibraryCompatibility {
  /// The library exports every entry point the App links against.
  compatible,

  /// The library is loadable but misses entry points; the user may continue.
  warning,

  /// The library cannot be used at all.
  fatal,
}

/// The result of checking a downloaded core library against the App.
final class CoreLibraryCheck {
  const CoreLibraryCheck({
    required this.compatibility,
    this.missingSymbols = const [],
    this.machine,
    this.reason,
  });

  final CoreLibraryCompatibility compatibility;

  /// JNI entry points the App links against but the library does not export.
  final List<String> missingSymbols;

  /// The `e_machine` value read from the library.
  final int? machine;

  /// Why the library cannot be used, when it cannot.
  final String? reason;

  bool get isUsable => compatibility != CoreLibraryCompatibility.fatal;
}

/// JNI entry points the App links against. The gomobile bootstrap comes
/// first, then the libXray surface the App calls, then the callback proxies
/// the Go runtime calls back through.
const coreLibraryRequiredSymbols = <String>[
  'Java_go_Seq_init',
  'Java_go_Seq_setContext',
  'Java_go_Seq_incGoRef',
  'Java_go_Seq_destroyRef',
  'Java_go_Universe__1init',
  'Java_libXray_LibXray__1init',
  'Java_libXray_LibXray_invoke',
  'Java_libXray_LibXray_registerDialerController',
  'Java_libXray_LibXray_registerListenerController',
  'Java_libXray_LibXray_registerProcessFinder',
  'Java_libXray_LibXray_resetDNS',
  'Java_libXray_LibXray_setDNS',
  'Java_libXray_LibXray_00024proxyDialerController_protectFd',
  'Java_libXray_LibXray_00024proxyProcessFinder_findProcessByConnection',
];

/// ELF machine values for the Android ABIs the App ships.
const _androidMachines = <CoreAbi, int>{CoreAbi.arm64: 183, CoreAbi.x64: 62};

/// The path of the native library inside the released Android archive.
const _androidLibraryEntries = <CoreAbi, String>{
  CoreAbi.arm64: 'jni/arm64-v8a/libgojni.so',
  CoreAbi.x64: 'jni/x86_64/libgojni.so',
};

/// The archive entry that holds the native library for this platform.
String? coreLibraryEntry(CorePlatform platform, CoreAbi abi) {
  if (platform == CorePlatform.android) {
    return _androidLibraryEntries[abi];
  }
  return null;
}

/// The ABI directory an Android archive uses for the native library.
String coreLibraryAbiDirectory(CoreAbi abi) => switch (abi) {
  CoreAbi.arm64 => 'arm64-v8a',
  CoreAbi.x64 => 'x86_64',
};

/// The ELF machine the native library must report for this platform.
int? coreLibraryMachine(CorePlatform platform, CoreAbi abi) {
  if (platform == CorePlatform.android) {
    return _androidMachines[abi];
  }
  return null;
}

/// Checks a downloaded native library against the entry points the App needs.
///
/// A missing entry point is a warning the user may accept; a library built
/// for another CPU or a file that is not a shared object cannot be used.
CoreLibraryCheck checkCoreLibrary(
  List<int> bytes, {
  required CorePlatform platform,
  required CoreAbi abi,
}) {
  final ElfDynamicSymbols parsed;
  try {
    parsed = parseElfDynamicSymbols(bytes);
  } on ElfFormatException catch (error) {
    return CoreLibraryCheck(
      compatibility: CoreLibraryCompatibility.fatal,
      reason: error.message,
    );
  }
  final expectedMachine = coreLibraryMachine(platform, abi);
  if (expectedMachine != null && parsed.machine != expectedMachine) {
    return CoreLibraryCheck(
      compatibility: CoreLibraryCompatibility.fatal,
      machine: parsed.machine,
      reason:
          'The library targets machine ${parsed.machine}, expected $expectedMachine',
    );
  }
  final missing = coreLibraryRequiredSymbols
      .where((symbol) => !parsed.contains(symbol))
      .toList(growable: false);
  if (missing.isEmpty) {
    return CoreLibraryCheck(
      compatibility: CoreLibraryCompatibility.compatible,
      machine: parsed.machine,
    );
  }
  return CoreLibraryCheck(
    compatibility: CoreLibraryCompatibility.warning,
    missingSymbols: missing,
    machine: parsed.machine,
    reason: 'The library does not export ${missing.length} required entries',
  );
}
