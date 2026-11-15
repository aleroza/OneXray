import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/service/advanced/xray/core_version/installer.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';

import '../../../../support/test_directory.dart';

final _now = DateTime.utc(2026, 11, 16, 12);

List<int> buildZip(List<ArchiveFile> files) {
  final archive = Archive();
  for (final file in files) {
    archive.add(file);
  }
  return ZipEncoder().encode(archive);
}

/// Real libXray archives wrap every entry in one directory named after the
/// asset, for example `libxray-linux-x64/xray`.
List<int> linuxZip({
  String xray = 'core-binary',
  String sharedLibrary = 'native-library',
  String header = 'core-header',
  List<String> extra = const [],
}) => buildZip([
  ArchiveFile.string('libxray-linux-x64/xray', xray),
  ArchiveFile.string('libxray-linux-x64/libXray.so', sharedLibrary),
  ArchiveFile.string('libxray-linux-x64/libXray.h', header),
  for (final name in extra)
    ArchiveFile.string('libxray-linux-x64/$name', 'extra'),
]);

String zipDigest(List<int> zip) => sha256.convert(zip).toString();

CoreAsset assetFor(
  List<int> zip, {
  String name = 'libxray-linux-x64.zip',
  int id = 42,
  String? digest,
}) => CoreAsset(
  id: id,
  name: name,
  size: zip.length,
  digest: 'sha256:${digest ?? zipDigest(zip)}',
  downloadUrl: 'https://example.invalid/$name',
);

CoreRelease releaseWith(CoreAsset asset) => CoreRelease(
  tag: 'v26.11.9',
  publishedAt: DateTime.utc(2026, 11, 9),
  prerelease: false,
  assets: [asset],
);

Matcher failureOf(FailureCategory category, String code) => isA<AppFailure>()
    .having((failure) => failure.category, 'category', category)
    .having((failure) => failure.code, 'code', code);

void main() {
  late Directory root;
  late CoreVersionStorage storage;

  setUp(() async {
    root = await createTestDirectory('core-installer');
    storage = CoreVersionStorage(root);
  });

  CoreInstaller installerFor(
    List<int> zip, {
    void Function()? onDownload,
    Object Function()? downloadFailure,
    CorePlatform Function()? platform,
    CoreAbi? Function()? abi,
    int? maxEntries,
    int? maxExpandedBytes,
    int? maxEntryBytes,
  }) {
    return CoreInstaller(
      storage: storage,
      maxEntries: maxEntries ?? CoreInstaller.defaultMaxEntries,
      maxExpandedBytes:
          maxExpandedBytes ?? CoreInstaller.defaultMaxExpandedBytes,
      maxEntryBytes: maxEntryBytes ?? CoreInstaller.defaultMaxEntryBytes,
      platform: platform ?? () => CorePlatform.linux,
      abi: abi ?? () => CoreAbi.x64,
      now: () => _now,
      download: (uri, destination, progress) async {
        expect(uri.scheme, 'https');
        onDownload?.call();
        if (downloadFailure != null) {
          await destination.writeAsBytes(const <int>[1, 2, 3]);
          throw downloadFailure();
        }
        await destination.writeAsBytes(zip);
        progress?.call(zip.length, zip.length);
      },
    );
  }

  Future<void> expectNothingPublished() async {
    if (await storage.versionsRoot.exists()) {
      expect(await storage.versionsRoot.list().toList(), isEmpty);
    }
    expect(await storage.stagingRoot.exists(), isFalse);
  }

  test(
    'installs a verified archive and publishes one manifest version',
    () async {
      final zip = linuxZip();
      final asset = assetFor(zip);
      final installer = installerFor(zip);

      final manifest = await installer.install(releaseWith(asset), asset);

      final installed = storage.versionDirectory('v26.11.9-42');
      final rootDir = Directory('${installed.path}/libxray-linux-x64');
      expect(await File('${rootDir.path}/xray').exists(), isTrue);
      expect(await File('${rootDir.path}/libXray.so').exists(), isTrue);
      expect(await File('${rootDir.path}/libXray.h').exists(), isTrue);
      expect(await File('${installed.path}/manifest.json').exists(), isTrue);
      expect(await storage.stagingRoot.exists(), isFalse);

      expect(manifest.releaseTag, 'v26.11.9');
      expect(manifest.assetId, 42);
      expect(manifest.assetName, 'libxray-linux-x64.zip');
      expect(manifest.assetSize, zip.length);
      expect(manifest.expectedSha256, zipDigest(zip));
      expect(manifest.platform, 'linux');
      expect(manifest.abi, 'x64');
      expect(manifest.installedAt, _now);
      expect(manifest.installDir, installed.path);
      String digestOf(String text) =>
          sha256.convert(utf8.encode(text)).toString();
      expect(
        manifest.installedSha256,
        sha256
            .convert(
              utf8.encode(
                'libxray-linux-x64/libXray.h ${digestOf('core-header')}\n'
                'libxray-linux-x64/libXray.so ${digestOf('native-library')}\n'
                'libxray-linux-x64/xray ${digestOf('core-binary')}\n',
              ),
            )
            .toString(),
      );
      final reread = await storage.readManifest('v26.11.9-42');
      expect(reread?.installedSha256, manifest.installedSha256);
    },
  );

  test('installs the real Windows archive layout', () async {
    final zip = buildZip([
      ArchiveFile.string('libxray-windows-x64/xray.exe', 'core-binary'),
      ArchiveFile.string('libxray-windows-x64/libXray.dll', 'native-library'),
      ArchiveFile.string('libxray-windows-x64/libXray.h', 'core-header'),
    ]);
    final asset = assetFor(zip, name: 'libxray-windows-x64.zip');
    final installer = installerFor(zip, platform: () => CorePlatform.windows);

    final manifest = await installer.install(releaseWith(asset), asset);
    expect(manifest.platform, 'windows');
    final rootDir = Directory(
      '${storage.versionDirectory("v26.11.9-42").path}/libxray-windows-x64',
    );
    expect(await File('${rootDir.path}/xray.exe').exists(), isTrue);
    expect(await File('${rootDir.path}/libXray.dll').exists(), isTrue);
    expect(await File('${rootDir.path}/libXray.h').exists(), isTrue);
  });

  test('installs the real Android archive layout', () async {
    final zip = buildZip([
      ArchiveFile.string('libxray-android/libXray.aar', 'android-archive'),
      ArchiveFile.string(
        'libxray-android/libXray-sources.jar',
        'android-sources',
      ),
    ]);
    final asset = assetFor(zip, name: 'libxray-android.zip');
    final installer = installerFor(
      zip,
      platform: () => CorePlatform.android,
      abi: () => CoreAbi.arm64,
    );

    final manifest = await installer.install(releaseWith(asset), asset);
    expect(manifest.platform, 'android');
    expect(manifest.abi, 'arm64');
    final rootDir = Directory(
      '${storage.versionDirectory("v26.11.9-42").path}/libxray-android',
    );
    expect(await File('${rootDir.path}/libXray.aar').exists(), isTrue);
    expect(await File('${rootDir.path}/libXray-sources.jar').exists(), isTrue);
  });

  test('a flat archive without the release directory is refused', () async {
    final zip = buildZip([
      ArchiveFile.string('xray', 'core'),
      ArchiveFile.string('libXray.so', 'library'),
      ArchiveFile.string('libXray.h', 'header'),
    ]);
    final asset = assetFor(zip);
    await expectLater(
      installerFor(zip).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveUnexpectedContent')),
    );
    await expectNothingPublished();
  });

  test('a mismatched release directory name is refused', () async {
    final zip = buildZip([
      ArchiveFile.string('libxray-linux-arm64/xray', 'core'),
      ArchiveFile.string('libxray-linux-arm64/libXray.so', 'library'),
      ArchiveFile.string('libxray-linux-arm64/libXray.h', 'header'),
    ]);
    final asset = assetFor(zip);
    await expectLater(
      installerFor(zip).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveUnexpectedContent')),
    );
    await expectNothingPublished();
  });

  test('files beside or inside the release directory beyond the allowlist are refused', () async {
    final extraFile = linuxZip(extra: ['evil.txt']);
    await expectLater(
      installerFor(extraFile)
          .install(releaseWith(assetFor(extraFile)), assetFor(extraFile)),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveUnexpectedContent')),
    );
    await expectNothingPublished();

    final missingHeader = buildZip([
      ArchiveFile.string('libxray-linux-x64/xray', 'core'),
      ArchiveFile.string('libxray-linux-x64/libXray.so', 'library'),
    ]);
    await expectLater(
      installerFor(
        missingHeader,
      ).install(releaseWith(assetFor(missingHeader)), assetFor(missingHeader)),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveUnexpectedContent')),
    );
    await expectNothingPublished();
  });

  test('a digest mismatch installs nothing', () async {
    final zip = linuxZip();
    final asset = assetFor(zip, digest: '0' * 64);

    await expectLater(
      installerFor(zip).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.input, 'coreAssetDigestMismatch')),
    );
    await expectNothingPublished();
  });

  test('a missing digest is refused before downloading', () async {
    final zip = linuxZip();
    var downloaded = false;
    final asset = CoreAsset(
      id: 42,
      name: 'libxray-linux-x64.zip',
      size: zip.length,
      downloadUrl: 'https://example.invalid/libxray-linux-x64.zip',
    );
    await expectLater(
      installerFor(
        zip,
        onDownload: () => downloaded = true,
      ).install(releaseWith(asset), asset),
      throwsA(
        failureOf(FailureCategory.configuration, 'coreAssetDigestMissing'),
      ),
    );
    expect(downloaded, isFalse);
    await expectNothingPublished();
  });

  test('an unknown ABI is refused before downloading', () async {
    final zip = linuxZip();
    var downloaded = false;
    final asset = assetFor(zip);
    await expectLater(
      installerFor(
        zip,
        abi: () => null,
        onDownload: () => downloaded = true,
      ).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.configuration, 'coreAbiUnknown')),
    );
    expect(downloaded, isFalse);
    await expectNothingPublished();
  });

  test('an asset that is not the platform archive is refused', () async {
    final zip = linuxZip();
    final asset = assetFor(zip, name: 'libxray-android.zip');
    await expectLater(
      installerFor(zip).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.input, 'coreAssetPlatformMismatch')),
    );
    await expectNothingPublished();
  });

  test('a zip entry escaping the root is refused', () async {
    final zip = buildZip([
      ArchiveFile.string('libxray-linux-x64/xray', 'core'),
      ArchiveFile.string('libxray-linux-x64/libXray.so', 'library'),
      ArchiveFile.string('libxray-linux-x64/libXray.h', 'header'),
      ArchiveFile.string('../escape.txt', 'evil'),
    ]);
    final asset = assetFor(zip);
    await expectLater(
      installerFor(zip).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveUnsafePath')),
    );
    await expectNothingPublished();
    expect(await File('${root.parent.path}/escape.txt').exists(), isFalse);
  });

  test('a symbolic link entry is refused', () async {
    final zip = buildZip([
      ArchiveFile.string('libxray-linux-x64/xray', 'core'),
      ArchiveFile.string('libxray-linux-x64/libXray.so', 'library'),
      ArchiveFile.string('libxray-linux-x64/libXray.h', 'header'),
      ArchiveFile.string('libxray-linux-x64/shortcut', 'xray')
        ..symbolicLink = 'xray',
    ]);
    final asset = assetFor(zip);
    await expectLater(
      installerFor(zip).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveSymlink')),
    );
    await expectNothingPublished();
  });

  test('too many entries are refused', () async {
    final zip = linuxZip();
    final asset = assetFor(zip);
    await expectLater(
      installerFor(zip, maxEntries: 2).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveTooManyEntries')),
    );
    await expectNothingPublished();
  });

  test('entry and total size limits are enforced', () async {
    final big = linuxZip(xray: 'x' * 64);
    await expectLater(
      installerFor(
        big,
        maxEntryBytes: 16,
      ).install(releaseWith(assetFor(big)), assetFor(big)),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveEntryTooLarge')),
    );
    await expectNothingPublished();

    final wide = linuxZip(xray: 'x' * 64, sharedLibrary: 'y' * 64);
    await expectLater(
      installerFor(
        wide,
        maxExpandedBytes: 96,
      ).install(releaseWith(assetFor(wide)), assetFor(wide)),
      throwsA(failureOf(FailureCategory.input, 'coreArchiveTooLarge')),
    );
    await expectNothingPublished();
  });

  test('an interrupted download publishes nothing', () async {
    final zip = linuxZip();
    final asset = assetFor(zip);
    await expectLater(
      installerFor(
        zip,
        downloadFailure: () => const SocketException('connection reset'),
      ).install(releaseWith(asset), asset),
      throwsA(failureOf(FailureCategory.network, 'coreInstallFailed')),
    );
    await expectNothingPublished();
  });

  test('reinstalling a version replaces the published directory', () async {
    final stale = storage.versionDirectory('v26.11.9-42');
    await stale.create(recursive: true);
    await File('${stale.path}/stale.txt').writeAsString('old');

    final zip = linuxZip();
    final asset = assetFor(zip);
    await installerFor(zip).install(releaseWith(asset), asset);

    expect(await File('${stale.path}/stale.txt').exists(), isFalse);
    expect(await File('${stale.path}/libxray-linux-x64/xray').exists(), isTrue);
  });
}
