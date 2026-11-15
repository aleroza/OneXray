import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/core/network/client.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:path/path.dart' as p;

/// Download progress in bytes; [total] is -1 when the server omits the
/// content length.
typedef CoreInstallProgress = void Function(int received, int total);

/// Streams one release asset to [destination]. Injectable so tests never
/// touch the network.
typedef CoreAssetDownload = Future<void> Function(
  Uri uri,
  File destination,
  CoreInstallProgress? onProgress,
);

/// Verifies the asset digest, unpacks the archive under staging limits and
/// publishes it atomically as `core/versions/<installationId>`.
final class CoreInstaller {
  static const defaultMaxDownloadBytes = 512 * 1024 * 1024;
  static const defaultMaxEntries = 512;
  static const defaultMaxExpandedBytes = 256 * 1024 * 1024;
  static const defaultMaxEntryBytes = 128 * 1024 * 1024;

  /// Every libXray archive holds one top-level directory named after the
  /// asset (`libxray-linux-x64` inside `libxray-linux-x64.zip`) containing
  /// exactly these entries and nothing else. The Apple archive carries the
  /// universal xcframework whose interior layout Apple owns.
  static const _platformContents = {
    CorePlatform.linux: {'xray', 'libXray.so', 'libXray.h'},
    CorePlatform.windows: {'xray.exe', 'libXray.dll', 'libXray.h'},
    CorePlatform.android: {'libXray.aar', 'libXray-sources.jar'},
    CorePlatform.apple: {'LibXray.xcframework'},
  };

  static final _unsafeDrivePrefix = RegExp(r'^[A-Za-z]:');
  static final _entrySeparator = RegExp(r'[\\/]');

  final CoreVersionStorage storage;
  final int maxDownloadBytes;
  final int maxEntries;
  final int maxExpandedBytes;
  final int maxEntryBytes;

  final CorePlatform? Function() _platform;
  final CoreAbi? Function() _abi;
  final DateTime Function() _now;
  late final CoreAssetDownload _download;

  CoreInstaller({
    required this.storage,
    CoreAssetDownload? download,
    CorePlatform? Function()? platform,
    CoreAbi? Function()? abi,
    DateTime Function()? now,
    this.maxDownloadBytes = defaultMaxDownloadBytes,
    this.maxEntries = defaultMaxEntries,
    this.maxExpandedBytes = defaultMaxExpandedBytes,
    this.maxEntryBytes = defaultMaxEntryBytes,
  }) : _platform = platform ?? currentCorePlatform,
       _abi = abi ?? currentCoreAbi,
       _now = now ?? DateTime.now {
    _download = download ?? _httpDownload;
  }

  /// Installs [asset] from [release] and returns the published manifest.
  /// Nothing is visible under versions/ until the fully verified staging
  /// directory is renamed as the last step; any failure leaves staging clean.
  Future<CoreVersionManifest> install(
    CoreRelease release,
    CoreAsset asset, {
    CoreInstallProgress? onProgress,
  }) async {
    final corePlatform = _platform();
    if (corePlatform == null) {
      throw const AppFailure(
        FailureCategory.configuration,
        'corePlatformUnsupported',
        cause: 'No libXray release asset exists for this platform and ABI',
      );
    }
    final digest = asset.sha256Hex;
    if (digest == null) {
      throw AppFailure(
        FailureCategory.configuration,
        'coreAssetDigestMissing',
        cause: '${asset.name} carries no sha256 digest to verify',
      );
    }
    final coreAbi = _abi();
    if (coreAbi == null) {
      throw const AppFailure(
        FailureCategory.configuration,
        'coreAbiUnknown',
        cause: 'The instruction set is unknown, so no asset can be verified',
      );
    }
    final expectedAsset = coreAssetNameFor(corePlatform, coreAbi);
    if (expectedAsset == null || asset.name != expectedAsset) {
      throw AppFailure(
        FailureCategory.input,
        'coreAssetPlatformMismatch',
        cause:
            '${asset.name} is not the $expectedAsset asset for this platform',
      );
    }
    final installationId = CoreVersionStorage.installationId(
      release.tag,
      asset.id,
    );
    final staging = Directory(p.join(storage.stagingRoot.path, installationId));
    final archiveFile = File(
      p.join(storage.stagingRoot.path, '$installationId.download.zip'),
    );
    try {
      await storage.clearStaging();
      await staging.create(recursive: true);
      await _download(_httpsUri(asset.downloadUrl), archiveFile, onProgress);
      final downloaded = await _sha256File(archiveFile);
      if (downloaded != digest) {
        throw AppFailure(
          FailureCategory.input,
          'coreAssetDigestMismatch',
          cause:
              '${asset.name} hashed to $downloaded instead of the published $digest',
        );
      }
      await _extractVerified(archiveFile, staging, corePlatform, asset.name);
      await archiveFile.delete();
      final manifest = CoreVersionManifest(
        releaseTag: release.tag,
        assetId: asset.id,
        assetName: asset.name,
        assetSize: asset.size,
        expectedSha256: digest,
        installedSha256: await _installedFingerprint(staging),
        platform: corePlatform.name,
        abi: coreAbi.name,
        installedAt: _now().toUtc(),
        installDir: storage.versionDirectory(installationId).path,
      );
      await storage.writeManifest(staging, manifest);
      await _publish(staging, installationId);
      return manifest;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_mapFailure(error), stackTrace);
    } finally {
      // The archive and any half-extracted tree live under staging, so an
      // interrupted install leaves no published version and no leftovers.
      await storage.clearStaging();
    }
  }

  Future<void> _extractVerified(
    File archiveFile,
    Directory destination,
    CorePlatform corePlatform,
    String assetName,
  ) async {
    final bytes = await archiveFile.readAsBytes();
    final contents = _platformContents[corePlatform]!;
    final rootName = _rootDirectory(assetName);
    var entries = 0;
    var declaredBytes = 0;
    final archive = ZipDecoder().decodeBytes(
      bytes,
      verify: true,
      callback: (entry) {
        entries += 1;
        if (entries > maxEntries) {
          throw AppFailure(
            FailureCategory.input,
            'coreArchiveTooManyEntries',
            cause: 'The archive holds more than $maxEntries entries',
          );
        }
        if (entry.isSymbolicLink) {
          throw AppFailure(
            FailureCategory.input,
            'coreArchiveSymlink',
            cause: '${entry.name} is a symbolic link',
          );
        }
        if (_isUnsafeEntryName(entry.name)) {
          throw AppFailure(
            FailureCategory.input,
            'coreArchiveUnsafePath',
            cause: '${entry.name} points outside the archive root',
          );
        }
        if (!entry.isFile) {
          return;
        }
        if (entry.size > maxEntryBytes) {
          throw AppFailure(
            FailureCategory.input,
            'coreArchiveEntryTooLarge',
            cause: '${entry.name} claims more than $maxEntryBytes bytes',
          );
        }
        declaredBytes += entry.size;
        if (declaredBytes > maxExpandedBytes) {
          throw AppFailure(
            FailureCategory.input,
            'coreArchiveTooLarge',
            cause: 'The archive claims more than $maxExpandedBytes bytes',
          );
        }
      },
    );
    try {
      await extractArchiveToDisk(
        archive,
        destination.path,
        throwOnError: true,
        maxSize: maxExpandedBytes,
      );
    } on ArchiveException catch (error) {
      throw AppFailure(
        FailureCategory.input,
        'coreArchiveInvalid',
        cause: error,
      );
    }
    await _checkExtractedTree(destination, rootName, contents);
  }

  /// Real libXray archives wrap their content in one directory named after
  /// the asset without its `.zip` suffix.
  static String _rootDirectory(String assetName) {
    if (!assetName.endsWith('.zip') || assetName.length <= 4) {
      throw AppFailure(
        FailureCategory.input,
        'coreAssetName',
        cause: 'Expected a .zip asset name, got "$assetName"',
      );
    }
    return assetName.substring(0, assetName.length - '.zip'.length);
  }

  /// Actual files on disk must match the declared limits, and the tree must
  /// be exactly `/<rootName>/<allowed entry>` with nothing beside the root
  /// directory and nothing else inside it.
  Future<void> _checkExtractedTree(
    Directory destination,
    String rootName,
    Set<String> contents,
  ) async {
    final root = Directory(p.join(destination.path, rootName));
    if (!await root.exists()) {
      throw AppFailure(
        FailureCategory.input,
        'coreArchiveUnexpectedContent',
        cause: 'The archive does not contain a $rootName directory',
      );
    }
    final children = <String, bool>{};
    var files = 0;
    var writtenBytes = 0;
    await for (final entity in destination.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: destination.path);
      if (entity is Link) {
        throw AppFailure(
          FailureCategory.input,
          'coreArchiveSymlink',
          cause: 'Extracted tree contains a link at $relative',
        );
      }
      final parts = p.split(relative);
      if (parts.length == 1) {
        if (parts.single != rootName || entity is! Directory) {
          throw AppFailure(
            FailureCategory.input,
            'coreArchiveUnexpectedContent',
            cause:
                'Expected a single $rootName directory at the root, found $relative',
          );
        }
        continue;
      }
      if (parts.length == 2) {
        children[parts[1]] = entity is Directory;
      }
      if (entity is! File) {
        continue;
      }
      files += 1;
      if (files > maxEntries) {
        throw AppFailure(
          FailureCategory.input,
          'coreArchiveTooManyEntries',
          cause: 'The archive extracted more than $maxEntries files',
        );
      }
      final size = await entity.stat().then((stat) => stat.size);
      if (size > maxEntryBytes) {
        throw AppFailure(
          FailureCategory.input,
          'coreArchiveEntryTooLarge',
          cause: '$relative expanded to more than $maxEntryBytes bytes',
        );
      }
      writtenBytes += size;
      if (writtenBytes > maxExpandedBytes) {
        throw AppFailure(
          FailureCategory.input,
          'coreArchiveTooLarge',
          cause: 'The archive expanded to more than $maxExpandedBytes bytes',
        );
      }
    }
    if (!children.keys.toSet().containsAll(contents) ||
        !contents.containsAll(children.keys)) {
      throw AppFailure(
        FailureCategory.input,
        'coreArchiveUnexpectedContent',
        cause:
            'Expected exactly ${contents.join(", ")} inside $rootName but found ${children.keys.join(", ")}',
      );
    }
    for (final name in contents) {
      final isDirectory = children[name]!;
      if (isDirectory != (name == _xcframework)) {
        throw AppFailure(
          FailureCategory.input,
          'coreArchiveUnexpectedContent',
          cause: '$rootName/$name has the wrong entry type',
        );
      }
    }
  }

  static const _xcframework = 'LibXray.xcframework';

  Future<void> _publish(Directory staging, String installationId) async {
    final target = storage.versionDirectory(installationId);
    await storage.versionsRoot.create(recursive: true);
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await staging.rename(target.path);
  }

  Future<String> _installedFingerprint(Directory root) async {
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path) != 'manifest.json') {
        files.add(entity);
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    final lines = <String>[];
    for (final file in files) {
      final digest = await sha256.bind(file.openRead()).first;
      lines.add(
        '${p.relative(file.path, from: root.path).replaceAll(p.separator, "/")} $digest\n',
      );
    }
    return sha256.convert(utf8.encode(lines.join())).toString();
  }

  static Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static Uri _httpsUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw AppFailure(
        FailureCategory.input,
        'coreAssetUrl',
        cause: 'An HTTPS asset URL is required: $value',
      );
    }
    return uri;
  }

  static bool _isUnsafeEntryName(String name) {
    if (name.isEmpty || name.contains('\x00')) {
      return true;
    }
    if (name.startsWith('/') ||
        name.startsWith(r'\') ||
        _unsafeDrivePrefix.hasMatch(name)) {
      return true;
    }
    return name.split(_entrySeparator).contains('..');
  }

  static Object _mapFailure(Object error) {
    if (error is AppFailure) {
      return error;
    }
    final category = failureCategory(error);
    if (category == FailureCategory.unknown) {
      return error;
    }
    return AppFailure(category, 'coreInstallFailed', cause: error);
  }

  /// The dart:io transport used in production: HTTPS only, bounded
  /// redirects, and the shared download User-Agent.
  Future<void> _httpDownload(
    Uri uri,
    File destination,
    CoreInstallProgress? onProgress,
  ) async {
    var current = uri;
    await NetClient().asyncInit();
    for (var redirects = 0; redirects <= 5; redirects++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          NetClient().downloadUserAgent,
        );
        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw const FormatException('Core asset redirect has no location');
          }
          current = current.resolve(location);
          if (current.scheme != 'https' || current.host.isEmpty) {
            throw const FormatException('Core asset left the HTTPS origin');
          }
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          throw AppFailure(
            FailureCategory.network,
            'httpStatus',
            cause: 'HTTP ${response.statusCode}',
          );
        }
        if (response.contentLength > maxDownloadBytes) {
          throw AppFailure(
            FailureCategory.input,
            'coreAssetTooLarge',
            cause: 'Core asset exceeds the $maxDownloadBytes byte limit',
          );
        }
        var received = 0;
        final sink = destination.openWrite();
        try {
          await sink.addStream(
            response
                .map((chunk) {
                  received += chunk.length;
                  if (received > maxDownloadBytes) {
                    throw const FormatException('Core asset file is too large');
                  }
                  onProgress?.call(received, response.contentLength);
                  return chunk;
                })
                .timeout(const Duration(seconds: 60)),
          );
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (received == 0) {
          throw const FormatException('Core asset file is empty');
        }
        return;
      } finally {
        client.close(force: true);
      }
    }
    throw const FormatException('Too many core asset redirects');
  }
}
