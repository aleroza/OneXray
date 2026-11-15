import 'package:onexray/core/tools/core_platform.dart';

/// Why core downloads are turned off. One reason is reported in evaluation
/// order so the UI can show a single concrete explanation.
enum CoreDownloadUnavailableReason {
  buildDisabled,
  unsupportedPlatform,
  unsupportedAbi,
  androidPlayDistribution,
  windowsMsixDistribution,
  appleCodeSigning,
}

/// Whether this build may download and switch Xray core versions. When
/// [enabled] the [platform], [abi] and [assetName] describe the exact release
/// asset that would be installed; when disabled [unavailableReason] explains
/// why.
final class CoreDownloadCapability {
  final bool enabled;
  final CorePlatform? platform;
  final CoreAbi? abi;
  final String? assetName;
  final CoreDownloadUnavailableReason? unavailableReason;

  const CoreDownloadCapability.enabled({
    required this.platform,
    required this.abi,
    required this.assetName,
  }) : enabled = true,
       unavailableReason = null;

  const CoreDownloadCapability.disabled(this.unavailableReason)
    : enabled = false,
      platform = null,
      abi = null,
      assetName = null;
}
