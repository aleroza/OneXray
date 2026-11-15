import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/service/advanced/xray/core_version/service.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../../../support/test_directory.dart';

const _linuxAsset = 'libxray-linux-x64.zip';

List<int> linuxZip() => ZipEncoder().encode(
  Archive()
    ..add(ArchiveFile.string('libxray-linux-x64/xray', 'core-binary'))
    ..add(ArchiveFile.string('libxray-linux-x64/libXray.so', 'library'))
    ..add(ArchiveFile.string('libxray-linux-x64/libXray.h', 'header')),
);

CoreAsset assetFor(List<int> zip, {String name = _linuxAsset}) => CoreAsset(
  id: 42,
  name: name,
  size: zip.length,
  digest: 'sha256:${sha256.convert(zip)}',
  downloadUrl: 'https://example.invalid/$name',
);

String githubBody(List<CoreAsset> assets) => jsonEncode([
  {
    'tag_name': 'v26.11.9',
    'published_at': '2026-11-09T10:00:00Z',
    'prerelease': false,
    'assets': [for (final asset in assets) asset.toJson()],
  },
]);

void main() {
  final preferencesStorage = InMemorySharedPreferencesAsync.empty();
  setUpAll(() => SharedPreferencesAsyncPlatform.instance = preferencesStorage);
  setUp(() => SharedPreferencesAsync().clear());

  late Directory root;
  late CoreVersionStorage storage;

  setUp(() async {
    root = await createTestDirectory('core-service');
    storage = CoreVersionStorage(root);
  });

  CoreDownloadCapability enabledCapability() =>
      const CoreDownloadCapability.enabled(
        platform: CorePlatform.linux,
        abi: CoreAbi.x64,
        assetName: _linuxAsset,
      );

  CoreVersionService serviceFor({
    CoreDownloadCapability? capability,
    List<int>? zip,
    void Function()? onDownload,
  }) => CoreVersionService(
    openStorage: () async => storage,
    capability: () =>
        capability ??
        const CoreDownloadCapability.disabled(
          CoreDownloadUnavailableReason.buildDisabled,
        ),
    catalogAssetName: () => _linuxAsset,
    catalogRequest: (uri, headers) async => (
      statusCode: 200,
      etag: '"fixture"',
      body: githubBody([assetFor(zip ?? linuxZip())]),
    ),
    assetDownload: (uri, destination, progress) async {
      onDownload?.call();
      final bytes = zip ?? linuxZip();
      await destination.writeAsBytes(bytes);
      progress?.call(bytes.length, bytes.length);
    },
  );

  Matcher failureOf(String code) =>
      isA<AppFailure>().having((f) => f.code, 'code', code);

  test('capability is reported without touching disk', () {
    expect(serviceFor().capability().enabled, isFalse);
    final enabled = serviceFor(capability: enabledCapability()).capability();
    expect(enabled.enabled, isTrue);
    expect(enabled.assetName, _linuxAsset);
  });

  test(
    'catalog answers through the injected transport and caches on disk',
    () async {
      final result = await serviceFor().catalog();
      expect(result.releases.single.tag, 'v26.11.9');
      expect(result.fromCache, isFalse);
      expect(await storage.catalogFile.exists(), isTrue);

      final cached = await serviceFor().catalog();
      expect(cached.fromCache, isTrue);
      expect(cached.releases.single.tag, 'v26.11.9');
    },
  );

  test('installing with the feature disabled downloads nothing', () async {
    var downloaded = false;
    final zip = linuxZip();
    final release = CoreRelease(
      tag: 'v26.11.9',
      publishedAt: DateTime.utc(2026, 11, 9),
      prerelease: false,
      assets: [assetFor(zip)],
    );
    await expectLater(
      serviceFor(onDownload: () => downloaded = true).install(release),
      throwsA(failureOf('coreDownloadsDisabled')),
    );
    expect(downloaded, isFalse);
    expect(await storage.versionsRoot.exists(), isFalse);
  });

  test('installing publishes the asset the capability selected', () async {
    final zip = linuxZip();
    final release = CoreRelease(
      tag: 'v26.11.9',
      publishedAt: DateTime.utc(2026, 11, 9),
      prerelease: false,
      assets: [assetFor(zip)],
    );
    var received = 0;
    final manifest = await serviceFor(
      capability: enabledCapability(),
      zip: zip,
    ).install(release, onProgress: (count, _) => received = count);

    expect(manifest.releaseTag, 'v26.11.9');
    expect(received, zip.length);
    final installed = await serviceFor(capability: enabledCapability())
        .installed();
    expect(installed.map((entry) => entry.installationId), ['v26.11.9-42']);
  });

  test('a release without the selected asset installs nothing', () async {
    final zip = linuxZip();
    final release = CoreRelease(
      tag: 'v26.11.9',
      publishedAt: DateTime.utc(2026, 11, 9),
      prerelease: false,
      assets: [assetFor(zip, name: 'libxray-windows-x64.zip')],
    );
    await expectLater(
      serviceFor(capability: enabledCapability(), zip: zip).install(release),
      throwsA(failureOf('coreReleaseAsset')),
    );
    expect(await storage.versionsRoot.exists(), isFalse);
  });

  test('selection round-trips and null restores the bundled core', () async {
    final service = serviceFor();
    expect(await service.activeInstallationId(), isNull);
    await service.select('v26.11.9-42');
    expect(await service.activeInstallationId(), 'v26.11.9-42');
    await service.clearSelection();
    expect(await service.activeInstallationId(), isNull);
  });

  test('the selected version cannot be removed, others can', () async {
    final directory = storage.versionDirectory('v26.11.9-42');
    await directory.create(recursive: true);
    final service = serviceFor();

    await service.select('v26.11.9-42');
    await expectLater(
      service.remove('v26.11.9-42'),
      throwsA(failureOf('coreVersionActive')),
    );
    expect(await directory.exists(), isTrue);

    await service.clearSelection();
    await service.remove('v26.11.9-42');
    expect(await directory.exists(), isFalse);
  });
}
