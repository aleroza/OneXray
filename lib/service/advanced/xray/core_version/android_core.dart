import 'dart:io';

import 'package:onexray/core/model/core_library_compatibility.dart';
import 'package:onexray/core/pigeon/host_api.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:path/path.dart' as p;

/// The native library of an installed Android core release.
final class AndroidCoreLibrary {
  const AndroidCoreLibrary({required this.path, required this.check});

  /// The path of the published library relative to the app files directory.
  final String path;

  /// What the library offers compared to the JNI contract the App needs.
  final CoreLibraryCheck check;
}

/// Publishes and selects the native library of an installed Android core.
///
/// The library is loaded inside the App process, so the platform publishes it
/// read-only and the App only announces which file the runtime should use.
/// The announcement is a small file the native bridge reads when the process
/// starts, which means a new version takes effect after the App restarts.
final class AndroidCoreService {
  static const _selectionFileName = 'selection.json';

  final Future<CoreVersionStorage> Function() _openStorage;
  final Future<String?> Function(
    String aarPath,
    String abi,
    String installationId,
  )
  _publishLibrary;
  final CoreAbi? Function() _abi;

  AndroidCoreService({
    Future<CoreVersionStorage> Function()? openStorage,
    Future<String?> Function(String aarPath, String abi, String installationId)?
    publishLibrary,
    CoreAbi? Function()? abi,
  }) : _openStorage = openStorage ?? CoreVersionStorage.open,
       _publishLibrary = publishLibrary ?? _platformPublish,
       _abi = abi ?? currentCoreAbi;

  /// Publishes the native library of an installed version and checks it
  /// against the JNI contract the App links against.
  ///
  /// Returns null when the platform does not publish native libraries or the
  /// installed archive does not carry one for this device.
  Future<AndroidCoreLibrary?> publishInstalledLibrary(
    CoreVersionManifest manifest,
  ) async {
    if (manifest.platform != CorePlatform.android.name) {
      return null;
    }
    final abi = _abi();
    if (abi == null) {
      return null;
    }
    final aar = await _findArchive(manifest.installDir);
    if (aar == null) {
      return null;
    }
    final installationId = p.basename(manifest.installDir);
    final published = await _publishLibrary(
      aar.path,
      coreLibraryAbiDirectory(abi),
      installationId,
    );
    if (published == null || published.isEmpty) {
      return null;
    }
    final storage = await _openStorage();
    final library = File(p.join(storage.root.path, published));
    if (!await library.exists()) {
      return null;
    }
    final bytes = await library.readAsBytes();
    return AndroidCoreLibrary(
      path: published,
      check: checkCoreLibrary(
        bytes,
        platform: CorePlatform.android,
        abi: abi,
      ),
    );
  }

  /// Announces the library the runtime should load, or clears the
  /// announcement so the bundled library is used again.
  Future<void> selectLibrary(String? relativePath) async {
    final storage = await _openStorage();
    final file = File(p.join(storage.coreRoot.path, _selectionFileName));
    if (relativePath == null || relativePath.isEmpty) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    await storage.writeJsonAtomically(file, {'libraryPath': relativePath});
  }

  /// The announcement the native bridge reads, if any.
  Future<String?> selectedLibraryPath() async {
    final storage = await _openStorage();
    final json = await storage.readJsonObject(
      File(p.join(storage.coreRoot.path, _selectionFileName)),
    );
    final value = json?['libraryPath'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<File?> _findArchive(String installDir) async {
    final root = Directory(installDir);
    if (!await root.exists()) {
      return null;
    }
    await for (final entity in root.list(recursive: true)) {
      if (entity is File && p.basename(entity.path) == 'libXray.aar') {
        return entity;
      }
    }
    return null;
  }

  static Future<String?> _platformPublish(
    String aarPath,
    String abi,
    String installationId,
  ) =>
      AppHostApi().publishCoreLibrary(aarPath, abi, installationId);
}
