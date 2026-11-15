import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/constants/build_capabilities.dart';
import 'package:onexray/core/ffi/windows/mode.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/service/advanced/xray/core_version/capability.dart';

void main() {
  CoreDownloadCapability evaluateFor({
    CorePlatform? platform = CorePlatform.linux,
    CoreAbi? abi = CoreAbi.x64,
    WindowsMode? windowsMode,
    String androidDistribution = 'direct',
  }) => CoreDownloadCapabilityService.evaluate(
    buildEnabled: true,
    platform: () => platform,
    abi: () => abi,
    windowsMode: windowsMode == null ? null : () => windowsMode,
    androidDistribution: androidDistribution,
  );

  group('build switch', () {
    test('disabled build turns the feature off regardless of the device', () {
      final capability = CoreDownloadCapabilityService.evaluate(
        buildEnabled: false,
        platform: () => CorePlatform.linux,
        abi: () => CoreAbi.x64,
      );
      expect(capability.enabled, isFalse);
      expect(
        capability.unavailableReason,
        CoreDownloadUnavailableReason.buildDisabled,
      );
      expect(capability.assetName, isNull);
    });

    test('the shipped default keeps downloads off', () {
      expect(coreDownloadsBuildEnabled, isFalse);
      expect(androidDistributionName, 'direct');
      expect(
        CoreDownloadCapabilityService.evaluate().unavailableReason,
        CoreDownloadUnavailableReason.buildDisabled,
      );
    });
  });

  group('platform', () {
    test('a platform without a libXray asset is unsupported', () {
      expect(
        evaluateFor(platform: null).unavailableReason,
        CoreDownloadUnavailableReason.unsupportedPlatform,
      );
    });

    test('apple stays off because the xcframework is code signed', () {
      for (final abi in CoreAbi.values) {
        final capability = evaluateFor(platform: CorePlatform.apple, abi: abi);
        expect(capability.enabled, isFalse);
        expect(
          capability.unavailableReason,
          CoreDownloadUnavailableReason.appleCodeSigning,
        );
      }
    });
  });

  group('distribution channel', () {
    test('Windows MSIX packages keep the bundled core', () {
      expect(
        evaluateFor(
          platform: CorePlatform.windows,
          windowsMode: WindowsMode.msix,
        ).unavailableReason,
        CoreDownloadUnavailableReason.windowsMsixDistribution,
      );
    });

    test('the Android Play channel keeps the bundled core', () {
      expect(
        evaluateFor(
          platform: CorePlatform.android,
          androidDistribution: 'play',
        ).unavailableReason,
        CoreDownloadUnavailableReason.androidPlayDistribution,
      );
    });

    test('the channel is not consulted for other platforms', () {
      expect(
        evaluateFor(
          platform: CorePlatform.linux,
          androidDistribution: 'play',
        ).enabled,
        isTrue,
      );
    });
  });

  group('abi and asset', () {
    test('an unknown ABI is refused with its own reason', () {
      expect(
        evaluateFor(abi: null).unavailableReason,
        CoreDownloadUnavailableReason.unsupportedAbi,
      );
    });

    test('an enabled evaluation reports the exact release asset', () {
      final cases = {
        (CorePlatform.linux, CoreAbi.x64): 'libxray-linux-x64.zip',
        (CorePlatform.linux, CoreAbi.arm64): 'libxray-linux-arm64.zip',
        (CorePlatform.windows, CoreAbi.x64): 'libxray-windows-x64.zip',
        (CorePlatform.windows, CoreAbi.arm64): 'libxray-windows-arm64.zip',
        (CorePlatform.android, CoreAbi.arm64): 'libxray-android.zip',
        (CorePlatform.android, CoreAbi.x64): 'libxray-android.zip',
      };
      for (final entry in cases.entries) {
        final capability = evaluateFor(
          platform: entry.key.$1,
          abi: entry.key.$2,
          windowsMode: WindowsMode.exe,
        );
        expect(capability.enabled, isTrue, reason: '${entry.key}');
        expect(capability.platform, entry.key.$1);
        expect(capability.abi, entry.key.$2);
        expect(capability.assetName, entry.value);
        expect(capability.unavailableReason, isNull);
      }
    });
  });
}
