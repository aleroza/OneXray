import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/tools/core_platform.dart';

void main() {
  test('maps platform and ABI onto the libXray release asset', () {
    const mapping = {
      (CorePlatform.linux, CoreAbi.x64): 'libxray-linux-x64.zip',
      (CorePlatform.linux, CoreAbi.arm64): 'libxray-linux-arm64.zip',
      (CorePlatform.windows, CoreAbi.x64): 'libxray-windows-x64.zip',
      (CorePlatform.windows, CoreAbi.arm64): 'libxray-windows-arm64.zip',
      (CorePlatform.android, CoreAbi.x64): 'libxray-android.zip',
      (CorePlatform.android, CoreAbi.arm64): 'libxray-android.zip',
    };
    for (final entry in mapping.entries) {
      final (platform, abi) = entry.key;
      expect(
        coreAssetNameFor(platform, abi),
        entry.value,
        reason: '$platform/$abi',
      );
    }
  });

  test('an unresolved ABI has no asset on platforms that select by ABI', () {
    for (final platform in [
      CorePlatform.linux,
      CorePlatform.windows,
      CorePlatform.android,
    ]) {
      expect(
        coreAssetNameFor(platform, null),
        isNull,
        reason: '$platform without an ABI',
      );
    }
  });

  test('the Apple archive is universal across ABIs', () {
    for (final abi in [null, ...CoreAbi.values]) {
      expect(
        coreAssetNameFor(CorePlatform.apple, abi),
        'libxray-apple-cgo.zip',
        reason: 'apple/$abi',
      );
    }
  });

  test('the running process resolves to a supported platform and ABI', () {
    expect(currentCorePlatform(), isNotNull);
    expect([...CoreAbi.values, null], contains(currentCoreAbi()));
  });
}
