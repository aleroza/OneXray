import 'package:onexray/core/constants/preferences.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/service/advanced/xray/core_version/catalog.dart';
import 'package:onexray/service/advanced/xray/core_version/capability.dart';
import 'package:onexray/service/advanced/xray/core_version/installer.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';

/// Single entry point the UI uses for core versions. Owns no state; the
/// active selection lives only in the app2.activeCoreVersion preference so a
/// missing or unknown value keeps meaning "bundled core".
final class CoreVersionService {
  final Future<CoreVersionStorage> Function() _openStorage;
  final CoreDownloadCapability Function() _capability;
  final String? Function()? catalogAssetName;
  final CoreCatalogRequest? catalogRequest;
  final CoreAssetDownload? assetDownload;

  CoreVersionService({
    Future<CoreVersionStorage> Function()? openStorage,
    CoreDownloadCapability Function()? capability,
    this.catalogAssetName,
    this.catalogRequest,
    this.assetDownload,
  }) : _openStorage = openStorage ?? CoreVersionStorage.open,
       _capability = capability ?? CoreDownloadCapabilityService.evaluate;

  CoreDownloadCapability capability() => _capability();

  Future<CoreCatalogResult> catalog({bool refresh = false}) async =>
      CoreCatalog(
        storage: await _openStorage(),
        assetName: catalogAssetName,
        request: catalogRequest,
      ).fetch(forceRefresh: refresh);

  Future<List<CoreInstalledVersion>> installed() async =>
      (await _openStorage()).listInstalled();

  /// Downloads and publishes the asset the capability selected for this
  /// device. Nothing here starts or stops the core; the active preference is
  /// applied on the next connection.
  Future<CoreVersionManifest> install(
    CoreRelease release, {
    void Function(int received, int total)? onProgress,
  }) async {
    final current = capability();
    if (!current.enabled) {
      throw const AppFailure(
        FailureCategory.configuration,
        'coreDownloadsDisabled',
        cause: 'This build does not allow downloading core versions',
      );
    }
    final asset = release.assetNamed(current.assetName!);
    if (asset == null) {
      throw AppFailure(
        FailureCategory.input,
        'coreReleaseAsset',
        cause: 'Release ${release.tag} carries no ${current.assetName} asset',
      );
    }
    return CoreInstaller(
      storage: await _openStorage(),
      download: assetDownload,
    ).install(release, asset, onProgress: onProgress);
  }

  Future<String?> activeInstallationId() =>
      PreferencesKey().readActiveCoreVersion();

  /// Null selects the bundled core; the key removal restores the fallback.
  Future<void> select(String? installationId) =>
      PreferencesKey().saveActiveCoreVersion(installationId);

  Future<void> remove(String installationId) async {
    if (await activeInstallationId() == installationId) {
      throw const AppFailure(
        FailureCategory.input,
        'coreVersionActive',
        cause: 'The selected core version must be replaced before removal',
      );
    }
    await (await _openStorage()).remove(installationId);
  }

  Future<void> clearSelection() => select(null);
}
