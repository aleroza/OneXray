import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/model/core_library_compatibility.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/service/advanced/xray/core_version/android_core.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:path/path.dart' as p;

import '../../../../support/elf_fixture.dart';

void main() {
  late Directory root;
  late CoreVersionStorage storage;

  CoreVersionManifest manifestFor(String installDir) => CoreVersionManifest(
    releaseTag: 'v26.11.9',
    assetId: 7,
    assetName: 'libxray-android.zip',
    assetSize: 1024,
    expectedSha256: 'a' * 64,
    installedSha256: 'b' * 64,
    platform: CorePlatform.android.name,
    abi: CoreAbi.arm64.name,
    installedAt: DateTime.utc(2026, 11, 9),
    installDir: installDir,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('android-core');
    storage = CoreVersionStorage(root);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<Directory> installedVersion() async {
    final directory = Directory(p.join(root.path, 'core/versions/v26.11.9-7'));
    final archive = Directory(p.join(directory.path, 'libxray-android'));
    await archive.create(recursive: true);
    await File(p.join(archive.path, 'libXray.aar')).writeAsBytes([1, 2, 3]);
    return directory;
  }

  test('publishes the library and accepts a matching contract', () async {
    final directory = await installedVersion();
    final library = buildElf(symbols: coreLibraryRequiredSymbols);
    AndroidCoreService service = AndroidCoreService(
      openStorage: () async => storage,
      abi: () => CoreAbi.arm64,
      publishLibrary: (aarPath, abi, installationId) async {
        expect(aarPath, endsWith('libXray.aar'));
        expect(abi, 'arm64-v8a');
        expect(installationId, 'v26.11.9-7');
        final target = File(
          p.join(directory.path, 'android/arm64-v8a/libgojni.so'),
        );
        await target.parent.create(recursive: true);
        await target.writeAsBytes(library);
        return 'core/versions/v26.11.9-7/android/arm64-v8a/libgojni.so';
      },
    );
    final result = await service.publishInstalledLibrary(
      manifestFor(directory.path),
    );
    expect(result, isNotNull);
    expect(result!.check.compatibility, CoreLibraryCompatibility.compatible);
    expect(result.check.missingSymbols, isEmpty);
  });

  test('reports a warning when the library misses an entry point', () async {
    final directory = await installedVersion();
    final library = buildElf(
      symbols: coreLibraryRequiredSymbols
          .where((symbol) => symbol != 'Java_libXray_LibXray_invoke')
          .toList(),
    );
    AndroidCoreService service = AndroidCoreService(
      openStorage: () async => storage,
      abi: () => CoreAbi.arm64,
      publishLibrary: (aarPath, abi, installationId) async {
        final target = File(
          p.join(directory.path, 'android/arm64-v8a/libgojni.so'),
        );
        await target.parent.create(recursive: true);
        await target.writeAsBytes(library);
        return 'core/versions/v26.11.9-7/android/arm64-v8a/libgojni.so';
      },
    );
    final result = await service.publishInstalledLibrary(
      manifestFor(directory.path),
    );
    expect(result, isNotNull);
    expect(result!.check.compatibility, CoreLibraryCompatibility.warning);
    expect(result.check.missingSymbols, ['Java_libXray_LibXray_invoke']);
  });

  test('refuses a library built for another CPU', () async {
    final directory = await installedVersion();
    final library = buildElf(
      symbols: coreLibraryRequiredSymbols,
      machine: 62,
    );
    AndroidCoreService service = AndroidCoreService(
      openStorage: () async => storage,
      abi: () => CoreAbi.arm64,
      publishLibrary: (aarPath, abi, installationId) async {
        final target = File(
          p.join(directory.path, 'android/arm64-v8a/libgojni.so'),
        );
        await target.parent.create(recursive: true);
        await target.writeAsBytes(library);
        return 'core/versions/v26.11.9-7/android/arm64-v8a/libgojni.so';
      },
    );
    final result = await service.publishInstalledLibrary(
      manifestFor(directory.path),
    );
    expect(result, isNotNull);
    expect(result!.check.compatibility, CoreLibraryCompatibility.fatal);
  });

  test('leaves other platforms alone', () async {
    final directory = await installedVersion();
    AndroidCoreService service = AndroidCoreService(
      openStorage: () async => storage,
      abi: () => CoreAbi.arm64,
      publishLibrary: (aarPath, abi, installationId) async =>
          'core/versions/v26.11.9-7/android/arm64-v8a/libgojni.so',
    );
    final manifest = manifestFor(directory.path).copyWith();
    final desktop = CoreVersionManifest(
      releaseTag: manifest.releaseTag,
      assetId: manifest.assetId,
      assetName: manifest.assetName,
      assetSize: manifest.assetSize,
      expectedSha256: manifest.expectedSha256,
      installedSha256: manifest.installedSha256,
      platform: CorePlatform.linux.name,
      abi: manifest.abi,
      installedAt: manifest.installedAt,
      installDir: manifest.installDir,
    );
    expect(await service.publishInstalledLibrary(desktop), isNull);
  });

  test('announces and clears the selected library', () async {
    AndroidCoreService service = AndroidCoreService(
      openStorage: () async => storage,
      abi: () => CoreAbi.arm64,
      publishLibrary: (aarPath, abi, installationId) async => null,
    );
    expect(await service.selectedLibraryPath(), isNull);
    await service.selectLibrary('core/versions/v26.11.9-7/android/arm64-v8a/libgojni.so');
    expect(
      await service.selectedLibraryPath(),
      'core/versions/v26.11.9-7/android/arm64-v8a/libgojni.so',
    );
    await service.selectLibrary(null);
    expect(await service.selectedLibraryPath(), isNull);
  });
}
