import 'package:onexray/core/constants/build_capabilities.dart';
import 'package:onexray/core/ffi/windows/mode.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/tools/core_platform.dart';

/// Decides whether this build and device may download core versions, in one
/// place so the page, the facade and future launch code never disagree.
/// The checks run in order: build switch, platform, distribution channel,
/// ABI, and finally whether a release asset exists for the pair.
final class CoreDownloadCapabilityService {
  const CoreDownloadCapabilityService._();

  /// Apple keeps the statically signed xcframework from the bundle, so core
  /// downloads stay off there regardless of the build switch.
  static CoreDownloadCapability evaluate({
    bool buildEnabled = coreDownloadsBuildEnabled,
    CorePlatform? Function() platform = currentCorePlatform,
    CoreAbi? Function() abi = currentCoreAbi,
    WindowsMode Function()? windowsMode,
    String androidDistribution = androidDistributionName,
  }) {
    if (!buildEnabled) {
      return const CoreDownloadCapability.disabled(
        CoreDownloadUnavailableReason.buildDisabled,
      );
    }
    final corePlatform = platform();
    if (corePlatform == null) {
      return const CoreDownloadCapability.disabled(
        CoreDownloadUnavailableReason.unsupportedPlatform,
      );
    }
    if (corePlatform == CorePlatform.apple) {
      return const CoreDownloadCapability.disabled(
        CoreDownloadUnavailableReason.appleCodeSigning,
      );
    }
    if (corePlatform == CorePlatform.windows) {
      final mode = windowsMode == null ? windowsBuildMode : windowsMode();
      if (mode == WindowsMode.msix) {
        return const CoreDownloadCapability.disabled(
          CoreDownloadUnavailableReason.windowsMsixDistribution,
        );
      }
    }
    if (corePlatform == CorePlatform.android &&
        androidDistribution == _playDistribution) {
      return const CoreDownloadCapability.disabled(
        CoreDownloadUnavailableReason.androidPlayDistribution,
      );
    }
    final coreAbi = abi();
    final assetName = coreAssetNameFor(corePlatform, coreAbi);
    if (coreAbi == null || assetName == null) {
      return const CoreDownloadCapability.disabled(
        CoreDownloadUnavailableReason.unsupportedAbi,
      );
    }
    return CoreDownloadCapability.enabled(
      platform: corePlatform,
      abi: coreAbi,
      assetName: assetName,
    );
  }

  static const _playDistribution = 'play';
}
