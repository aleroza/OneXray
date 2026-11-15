import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';

import '../../../../support/test_directory.dart';

CoreVersionManifest manifestFor(String tag, {int assetId = 7}) =>
    CoreVersionManifest(
      releaseTag: tag,
      assetId: assetId,
      assetName: 'libxray-linux-x64.zip',
      assetSize: 1024,
      expectedSha256: 'ab' * 32,
      installedSha256: 'cd' * 32,
      platform: 'linux',
      abi: 'x64',
      installedAt: DateTime.utc(2026, 11, 9, 12),
      installDir: '/opt/core/versions/$tag-$assetId',
    );

void main() {
  late Directory root;
  late CoreVersionStorage storage;

  setUp(() async {
    root = await createTestDirectory('core-version-storage');
    storage = CoreVersionStorage(root);
  });

  test('the layout roots every path under the core directory', () {
    expect(storage.coreRoot.path, '${root.path}/core');
    expect(storage.catalogFile.path, '${root.path}/core/catalog.json');
    expect(storage.versionsRoot.path, '${root.path}/core/versions');
    expect(storage.stagingRoot.path, '${root.path}/core/staging');
    expect(
      storage.versionDirectory('v26.11.9-7').path,
      '${root.path}/core/versions/v26.11.9-7',
    );
    expect(
      storage.manifestFile('v26.11.9-7').path,
      '${root.path}/core/versions/v26.11.9-7/manifest.json',
    );
  });

  test('installation ids stay safe directory names', () {
    expect(CoreVersionStorage.installationId('v26.11.9', 42), 'v26.11.9-42');
    for (final tag in ['../evil', '', 'a/b']) {
      expect(
        () => CoreVersionStorage.installationId(tag, 1),
        throwsA(
          isA<AppFailure>()
              .having(
                (failure) => failure.category,
                'category',
                FailureCategory.input,
              )
              .having((failure) => failure.code, 'code', 'coreInstallationId'),
        ),
        reason: tag,
      );
    }
    expect(
      () => storage.versionDirectory('../escape'),
      throwsA(isA<AppFailure>()),
    );
  });

  test('manifests round-trip through manifest.json', () async {
    final id = 'v26.11.9-7';
    final directory = storage.versionDirectory(id);
    await directory.create(recursive: true);
    await storage.writeManifest(directory, manifestFor('v26.11.9'));

    final read = await storage.readManifest(id);
    expect(read, isNotNull);
    expect(read!.releaseTag, 'v26.11.9');
    expect(read.assetId, 7);
    expect(read.assetName, 'libxray-linux-x64.zip');
    expect(read.assetSize, 1024);
    expect(read.expectedSha256, 'ab' * 32);
    expect(read.installedSha256, 'cd' * 32);
    expect(read.platform, 'linux');
    expect(read.abi, 'x64');
    expect(read.installedAt, DateTime.utc(2026, 11, 9, 12));
    expect(read.installDir, '/opt/core/versions/v26.11.9-7');
    expect(await storage.readManifest('v25.1.1-1'), isNull);
  });

  test(
    'listInstalled reports published versions and skips damaged ones',
    () async {
      for (final tag in ['v26.11.9', 'v26.11.10']) {
        final id = '$tag-7';
        final directory = storage.versionDirectory(id);
        await directory.create(recursive: true);
        await storage.writeManifest(directory, manifestFor(tag));
      }
      await storage.versionDirectory('v26.9.1-7').create(recursive: true);
      await File('${storage.versionDirectory("v26.9.1-7").path}/manifest.json')
          .writeAsString('{"releaseTag": 42}');

      final installed = await storage.listInstalled();
      expect(installed.map((entry) => entry.installationId), [
        'v26.11.10-7',
        'v26.11.9-7',
      ]);
      expect(installed.first.manifest.releaseTag, 'v26.11.10');
    },
  );

  test(
    'remove deletes the version directory, clearStaging the staging tree',
    () async {
      final id = 'v26.11.9-7';
      final directory = storage.versionDirectory(id);
      await directory.create(recursive: true);
      await storage.writeManifest(directory, manifestFor('v26.11.9'));
      final leftover = File('${storage.stagingRoot.path}/half.json');
      await leftover.create(recursive: true);

      await storage.remove(id);
      expect(await directory.exists(), isFalse);
      expect(await storage.listInstalled(), isEmpty);

      await storage.clearStaging();
      expect(await storage.stagingRoot.exists(), isFalse);
      await storage.clearStaging();
    },
  );

  test(
    'atomic JSON writes replace content and leave no temporary file',
    () async {
      final file = storage.catalogFile;
      await storage.writeJsonAtomically(file, {'etag': 'E1'});
      await storage.writeJsonAtomically(file, {'etag': 'E2'});
      expect(await storage.readJsonObject(file), {'etag': 'E2'});
      expect(await File('${file.path}.tmp').exists(), isFalse);
      expect(
        await storage.readJsonObject(File('${file.path}.missing')),
        isNull,
      );
    },
  );
}
