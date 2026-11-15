import 'dart:ffi';

import 'package:onexray/core/tools/platform.dart';

/// Platforms that receive versioned libXray release assets.
enum CorePlatform { linux, windows, android, apple }

/// Instruction sets used to select a desktop libXray asset.
enum CoreAbi { x64, arm64 }

/// The catalog platform for the process, or null when this platform has no
/// versioned libXray asset.
CorePlatform? currentCorePlatform() {
  if (AppPlatform.isAndroid) {
    return CorePlatform.android;
  }
  if (AppPlatform.isIOS || AppPlatform.isMacOS) {
    return CorePlatform.apple;
  }
  if (AppPlatform.isWindows) {
    return CorePlatform.windows;
  }
  if (AppPlatform.isLinux) {
    return CorePlatform.linux;
  }
  return null;
}

/// The process instruction set, or null when it is not supported. An unknown
/// ABI is never guessed into x64.
CoreAbi? currentCoreAbi() {
  return switch (Abi.current()) {
    Abi.androidX64 ||
    Abi.fuchsiaX64 ||
    Abi.iosX64 ||
    Abi.linuxX64 ||
    Abi.macosX64 ||
    Abi.windowsX64 => CoreAbi.x64,
    Abi.androidArm64 ||
    Abi.fuchsiaArm64 ||
    Abi.iosArm64 ||
    Abi.linuxArm64 ||
    Abi.macosArm64 ||
    Abi.windowsArm64 => CoreAbi.arm64,
    _ => null,
  };
}

/// The libXray release asset carrying the core for a platform and ABI, or
/// null for a combination without a published asset. The Apple archive holds
/// one universal xcframework, so it does not depend on the ABI.
String? coreAssetNameFor(CorePlatform platform, CoreAbi? abi) {
  return switch ((platform, abi)) {
    (CorePlatform.linux, CoreAbi.x64) => 'libxray-linux-x64.zip',
    (CorePlatform.linux, CoreAbi.arm64) => 'libxray-linux-arm64.zip',
    (CorePlatform.windows, CoreAbi.x64) => 'libxray-windows-x64.zip',
    (CorePlatform.windows, CoreAbi.arm64) => 'libxray-windows-arm64.zip',
    (CorePlatform.android, CoreAbi.x64 || CoreAbi.arm64) =>
      'libxray-android.zip',
    (CorePlatform.apple, _) => 'libxray-apple-cgo.zip',
    _ => null,
  };
}
