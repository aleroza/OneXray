import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/service/advanced/xray/core_version/executable.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:path/path.dart' as p;

import '../../../../support/test_directory.dart';

void main() {
  late CoreVersionStorage storage;
  late String installDir;

  setUp(() async {
    storage = CoreVersionStorage(await createTestDirectory('core-executable'));
    installDir = storage.versionDirectory('v26.11.9-42').path;
  });

  Future<File> extractedBinary(String content) async {
    final binary = File(
      p.join(
        installDir,
        'libxray-linux-x64',
        Platform.isWindows ? 'xray.exe' : 'xray',
      ),
    );
    await binary.parent.create(recursive: true);
    await binary.writeAsString(content);
    return binary;
  }

  Future<void> writeManifest() async {
    await storage.writeManifest(
      Directory(installDir),
      CoreVersionManifest(
        releaseTag: 'v26.11.9',
        assetId: 42,
        assetName: 'libxray-linux-x64.zip',
        assetSize: 1234,
        expectedSha256: 'a' * 64,
        installedSha256: 'b' * 64,
        platform: 'linux',
        abi: 'x64',
        installedAt: DateTime.utc(2026, 11, 10),
        installDir: installDir,
      ),
    );
  }

  Future<String?> prepare() =>
      prepareCoreExecutable('v26.11.9-42', openStorage: () async => storage);

  test(
    'the extracted binary is published under the canonical core name',
    () async {
      final source = await extractedBinary('core-binary');
      await writeManifest();

      final path = await prepare();

      expect(
        path,
        p.join(
          installDir,
          Platform.isWindows ? 'OneXrayCore.exe' : 'OneXrayCore',
        ),
      );
      final target = File(path!);
      expect(await target.exists(), isTrue);
      expect(await target.readAsString(), 'core-binary');
      // The canonical name is the process discovery key; the temp file is gone.
      expect(await File('$path.tmp').exists(), isFalse);
      expect(await source.exists(), isTrue);
      if (!Platform.isWindows) {
        final stat = await FileStat.stat(path);
        expect(stat.mode & int.parse('111', radix: 8), isNot(0));
      }
    },
  );

  test('a repeated call with an unchanged source changes nothing', () async {
    await extractedBinary('core-binary');
    await writeManifest();
    final path = await prepare();

    // Same length, different bytes: a size match must be treated as prepared.
    await File(path!).writeAsString('other-bytes');
    expect(await prepare(), path);
    expect(await File(path).readAsString(), 'other-bytes');
  });

  test('a changed source is republished under the canonical name', () async {
    final source = await extractedBinary('core-binary');
    await writeManifest();
    final path = await prepare();
    await source.writeAsString('replacement-binary-longer');

    expect(await prepare(), path);
    expect(await File(path!).readAsString(), 'replacement-binary-longer');
  });

  test('a missing manifest or binary yields no path', () async {
    expect(await prepare(), isNull);
    await writeManifest();
    expect(await prepare(), isNull);
  });
}
