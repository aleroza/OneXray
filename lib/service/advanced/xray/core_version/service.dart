import 'package:onexray/core/constants/preferences.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/core/model/core_library_compatibility.dart';
import 'package:onexray/service/advanced/xray/core_version/android_core.dart';
import 'package:onexray/service/advanced/xray/core_version/catalog.dart';
import 'package:onexray/service/advanced/xray/core_version/capability.dart';
import 'package:onexray/service/advanced/xray/core_version/executable.dart';
import 'package:onexray/service/advanced/xray/core_version/installer.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:onexray/service/connect/coordinator.dart';
import 'package:onexray/service/connect/runtime.dart';

/// Single entry point the UI uses for core versions. Owns no state; the
/// active selection lives only in the app2.activeCoreVersion preference so a
/// missing or unknown value keeps meaning "bundled core".
final class CoreVersionService {
  final Future<CoreVersionStorage> Function() _openStorage;
  final CoreDownloadCapability Function() _capability;
  final Future<ConnectionRuntime?> Function()? _readCurrentRuntime;
  final Future<void> Function()? _disconnect;
  final String? Function()? catalogAssetName;
  final CoreCatalogRequest? catalogRequest;
  final CoreAssetDownload? assetDownload;
  final AndroidCoreService? androidCore;

  CoreVersionService({
    Future<CoreVersionStorage> Function()? openStorage,
    CoreDownloadCapability Function()? capability,
    this._readCurrentRuntime,
    this._disconnect,
    this.catalogAssetName,
    this.catalogRequest,
    this.assetDownload,
    this.androidCore,
  }) : _openStorage = openStorage ?? CoreVersionStorage.open,
       _capability = capability ?? CoreDownloadCapabilityService.evaluate;

  // Touching the coordinator singleton is deferred until a connection call,
  // so constructing the service (for example to read the capability) never
  // initializes connection machinery.
  Future<ConnectionRuntime?> Function() get _currentRuntime =>
      _readCurrentRuntime ?? ConnectionCoordinator.instance.readCurrentRuntime;

  Future<void> Function() get _stopConnection =>
      _disconnect ?? ConnectionCoordinator.instance.disconnect;

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
    final manifest = await CoreInstaller(
      storage: await _openStorage(),
      download: assetDownload,
    ).install(release, asset, onProgress: onProgress);
    return _publishAndroidLibrary(manifest);
  }

  /// Publishes the native library of an Android release and records what it
  /// offers compared to the JNI contract the App links against. Other
  /// platforms have no native library to publish.
  Future<CoreVersionManifest> _publishAndroidLibrary(
    CoreVersionManifest manifest,
  ) async {
    final android = androidCore ?? AndroidCoreService();
    try {
      final library = await android.publishInstalledLibrary(manifest);
      if (library == null) {
        return manifest;
      }
      final updated = manifest.copyWith(
        libraryPath: library.path,
        compatibility: library.check.compatibility.name,
        missingSymbols: library.check.missingSymbols,
      );
      final storage = await _openStorage();
      final installationId = updated.installDir.split('/').last;
      await storage.writeManifest(
        storage.versionDirectory(installationId),
        updated,
      );
      return updated;
    } catch (_) {
      return manifest;
    }
  }

  Future<String?> activeInstallationId() =>
      PreferencesKey().readActiveCoreVersion();

  /// Null selects the bundled core; the key removal restores the fallback.
  Future<void> select(String? installationId) =>
      PreferencesKey().saveActiveCoreVersion(installationId);

  /// The canonical executable of the selected version, prepared for launch,
  /// or null when nothing is selected or the selected files are gone. A
  /// broken installation never throws: the launch paths fall back to the
  /// bundled core and the screen reports the selection as unavailable.
  Future<String?> activeExecutablePath() async {
    try {
      final installationId = await activeInstallationId();
      if (installationId == null) {
        return null;
      }
      return await prepareCoreExecutable(
        installationId,
        openStorage: _openStorage,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> isConnectionActive() async {
    try {
      return await _currentRuntime() != null;
    } catch (_) {
      return false;
    }
  }

  /// Stops the running connection before a core switch. Reports null when no
  /// connection had to be stopped, the failure otherwise; the caller decides
  /// whether an unstopped connection still allows saving the selection.
  Future<Object?> disconnectActiveConnection() async {
    try {
      if (await _currentRuntime() == null) {
        return null;
      }
      await _stopConnection();
      return null;
    } catch (error) {
      return error;
    }
  }

  /// Applies the selection the launch paths use on the next connection.
  /// Switching to a downloaded version first stops the running connection so
  /// the new core actually starts; the selection is saved even when stopping
  /// fails, and the failure is then reported to the caller.
  Future<void> activate(String? installationId) async {
    final android = androidCore ?? AndroidCoreService();
    if (installationId == null) {
      await select(null);
      await _announceLibrary(android, null);
      return;
    }
    final disconnectFailure = await disconnectActiveConnection();
    await select(installationId);
    await _announceLibrary(
      android,
      await _libraryPathOf(installationId),
    );
    if (disconnectFailure != null) {
      throw AppFailure(
        FailureCategory.runtime,
        'coreVersionsDisconnectFailed',
        cause: disconnectFailure,
      );
    }
  }

  /// Tells the native side which library the runtime should load. The
  /// announcement is best effort: when it fails the runtime keeps the
  /// bundled core, which is the safe fallback.
  Future<void> _announceLibrary(
    AndroidCoreService android,
    String? libraryPath,
  ) async {
    try {
      await android.selectLibrary(libraryPath);
    } catch (_) {}
  }

  /// The published native library of an installed version, if it has one.
  Future<String?> _libraryPathOf(String installationId) async {
    final installed = await (await _openStorage()).listInstalled();
    for (final entry in installed) {
      if (entry.installationId == installationId) {
        return entry.manifest.libraryPath;
      }
    }
    return null;
  }

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

  /// What the published library of an installed version offers compared to
  /// the JNI contract the App links against.
  CoreLibraryCheck? compatibilityOf(CoreInstalledVersion installed) {
    final compatibility = installed.manifest.compatibility;
    if (compatibility == null) {
      return null;
    }
    final verdict = CoreLibraryCompatibility.values.firstWhere(
      (value) => value.name == compatibility,
      orElse: () => CoreLibraryCompatibility.fatal,
    );
    return CoreLibraryCheck(
      compatibility: verdict,
      missingSymbols: installed.manifest.missingSymbols,
    );
  }
}
