import 'dart:convert';
import 'dart:io';

import 'package:onexray/core/errors/failure.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Contents of one installed core version's manifest.json. Installed cores
/// are identified by [CoreVersionStorage.installationId], never by this file.
final class CoreVersionManifest {
  final String releaseTag;
  final int assetId;
  final String assetName;
  final int assetSize;

  /// SHA-256 hex from the release asset digest, verified before extraction.
  final String expectedSha256;

  /// SHA-256 hex recomputed over the extracted files after installation.
  final String? installedSha256;
  final String platform;
  final String? abi;
  final DateTime installedAt;
  final String installDir;

  const CoreVersionManifest({
    required this.releaseTag,
    required this.assetId,
    required this.assetName,
    required this.assetSize,
    required this.expectedSha256,
    required this.installedSha256,
    required this.platform,
    required this.abi,
    required this.installedAt,
    required this.installDir,
  });

  /// Manifests that do not match this schema return null; one damaged file
  /// must not hide the other installed versions.
  static CoreVersionManifest? tryParse(Map<String, dynamic> json) {
    final releaseTag = json['releaseTag'];
    final assetId = json['assetId'];
    final assetName = json['assetName'];
    final assetSize = json['assetSize'];
    final expectedSha256 = json['expectedSha256'];
    final installedSha256 = json['installedSha256'];
    final platform = json['platform'];
    final abi = json['abi'];
    final installedAt = json['installedAt'];
    final installDir = json['installDir'];
    if (releaseTag is! String ||
        releaseTag.isEmpty ||
        assetId is! int ||
        assetName is! String ||
        assetName.isEmpty ||
        assetSize is! int ||
        expectedSha256 is! String ||
        installedSha256 != null && installedSha256 is! String ||
        platform is! String ||
        platform.isEmpty ||
        abi != null && abi is! String ||
        installedAt is! String ||
        installDir is! String ||
        installDir.isEmpty) {
      return null;
    }
    final installed = DateTime.tryParse(installedAt);
    if (installed == null) {
      return null;
    }
    return CoreVersionManifest(
      releaseTag: releaseTag,
      assetId: assetId,
      assetName: assetName,
      assetSize: assetSize,
      expectedSha256: expectedSha256,
      installedSha256: installedSha256 is String ? installedSha256 : null,
      platform: platform,
      abi: abi is String ? abi : null,
      installedAt: installed,
      installDir: installDir,
    );
  }

  Map<String, Object?> toJson() => {
    'releaseTag': releaseTag,
    'assetId': assetId,
    'assetName': assetName,
    'assetSize': assetSize,
    'expectedSha256': expectedSha256,
    'installedSha256': installedSha256,
    'platform': platform,
    'abi': abi,
    'installedAt': installedAt.toIso8601String(),
    'installDir': installDir,
  };
}

/// One published core version with its manifest.
final class CoreInstalledVersion {
  final String installationId;
  final CoreVersionManifest manifest;

  const CoreInstalledVersion({
    required this.installationId,
    required this.manifest,
  });
}

/// Disk layout for downloadable core versions:
/// `<app support>/core/{catalog.json, versions/<installationId>/, staging/}`.
/// Every JSON file is written atomically, and publication is a rename from
/// staging into versions/, so an interrupted install never publishes a
/// partially extracted version.
final class CoreVersionStorage {
  /// The application support directory owning the `core` root.
  final Directory root;

  CoreVersionStorage(this.root);

  static Future<CoreVersionStorage> open() async =>
      CoreVersionStorage(await getApplicationSupportDirectory());

  static final _safeInstallationId = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );

  Directory get coreRoot => Directory(p.join(root.path, 'core'));

  File get catalogFile => File(p.join(coreRoot.path, 'catalog.json'));

  Directory get versionsRoot => Directory(p.join(coreRoot.path, 'versions'));

  Directory get stagingRoot => Directory(p.join(coreRoot.path, 'staging'));

  /// A directory name that cannot escape versions/. Tags that are not safe
  /// are rejected instead of sanitized.
  static String installationId(String tag, int assetId) {
    final id = '$tag-$assetId';
    if (!_safeInstallationId.hasMatch(id)) {
      throw AppFailure(
        FailureCategory.input,
        'coreInstallationId',
        cause: 'Cannot derive a safe directory name from "$tag"',
      );
    }
    return id;
  }

  Directory versionDirectory(String installationId) =>
      Directory(p.join(versionsRoot.path, _checkedId(installationId)));

  File manifestFile(String installationId) =>
      File(p.join(versionDirectory(installationId).path, 'manifest.json'));

  Future<CoreVersionManifest?> readManifest(String installationId) async {
    final json = await readJsonObject(manifestFile(installationId));
    return json == null ? null : CoreVersionManifest.tryParse(json);
  }

  Future<void> writeManifest(
    Directory directory,
    CoreVersionManifest manifest,
  ) => writeJsonAtomically(
    File(p.join(directory.path, 'manifest.json')),
    manifest.toJson(),
  );

  /// Published versions whose manifest parses, ordered by installation id.
  /// Directories without a readable manifest are skipped so one damaged
  /// entry cannot hide the rest; `remove` still cleans them up.
  Future<List<CoreInstalledVersion>> listInstalled() async {
    final result = <CoreInstalledVersion>[];
    if (!await versionsRoot.exists()) {
      return result;
    }
    await for (final entity in versionsRoot.list()) {
      if (entity is! Directory ||
          !_safeInstallationId.hasMatch(p.basename(entity.path))) {
        continue;
      }
      final id = p.basename(entity.path);
      final json = await readJsonObject(
        File(p.join(entity.path, 'manifest.json')),
      );
      final manifest = json == null ? null : CoreVersionManifest.tryParse(json);
      if (manifest != null) {
        result.add(
          CoreInstalledVersion(installationId: id, manifest: manifest),
        );
      }
    }
    result.sort(
      (left, right) => left.installationId.compareTo(right.installationId),
    );
    return result;
  }

  Future<void> remove(String installationId) async {
    final directory = versionDirectory(installationId);
    if (await directory.exists()) {
      await _guard(() => directory.delete(recursive: true));
    }
  }

  Future<void> clearStaging() async {
    if (await stagingRoot.exists()) {
      await _guard(() => stagingRoot.delete(recursive: true));
    }
  }

  Future<Map<String, dynamic>?> readJsonObject(File file) async {
    String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  /// Writes to a sibling temporary file and renames it over [file]. On
  /// Windows a rename over an existing target fails, so the target is
  /// removed just before the second rename attempt.
  Future<void> writeJsonAtomically(File file, Map<String, Object?> json) async {
    final temporary = File('${file.path}.tmp');
    await _guard(() async {
      await file.parent.create(recursive: true);
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        if (await file.exists()) {
          await file.delete();
        }
        await temporary.rename(file.path);
      }
    });
  }

  static String _checkedId(String installationId) {
    if (!_safeInstallationId.hasMatch(installationId)) {
      throw AppFailure(
        FailureCategory.input,
        'coreInstallationId',
        cause: '"$installationId" is not a safe directory name',
      );
    }
    return installationId;
  }

  static Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on FileSystemException catch (error) {
      throw AppFailure(FailureCategory.storage, 'coreVersionIo', cause: error);
    }
  }
}
