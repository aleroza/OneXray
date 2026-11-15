import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/core/pigeon/host_api.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/shared/page_cubit.dart';
import 'package:onexray/service/advanced/xray/core_version/service.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:onexray/service/shared/failure.dart';

const _notProvided = Object();

@immutable
class CoreVersionsPageState {
  final CoreDownloadCapability capability;
  final String bundledVersion;
  final List<CoreInstalledVersion> installed;
  final String? activeInstallationId;
  final List<CoreRelease> available;
  final bool catalogLoaded;
  final bool catalogStale;
  final bool catalogRefreshing;
  final Object? catalogFailure;
  final bool loading;
  final bool failed;
  final Object? failure;
  final String? downloadingTag;
  final double? downloadProgress;
  final bool verifying;
  final Set<String> activating;
  final Set<String> deleting;
  final Map<String, String> errors;

  CoreVersionsPageState({
    required this.capability,
    this.bundledVersion = '—',
    List<CoreInstalledVersion> installed = const [],
    this.activeInstallationId,
    List<CoreRelease> available = const [],
    this.catalogLoaded = false,
    this.catalogStale = false,
    this.catalogRefreshing = false,
    this.catalogFailure,
    this.loading = true,
    this.failed = false,
    this.failure,
    this.downloadingTag,
    this.downloadProgress,
    this.verifying = false,
    Set<String> activating = const {},
    Set<String> deleting = const {},
    Map<String, String> errors = const {},
  }) : installed = List.unmodifiable(installed),
       available = List.unmodifiable(available),
       activating = Set.unmodifiable(activating),
       deleting = Set.unmodifiable(deleting),
       errors = Map.unmodifiable(errors);

  bool get bundledActive => activeInstallationId == null;
  bool get busy =>
      downloadingTag != null || activating.isNotEmpty || deleting.isNotEmpty;
  bool operationBusy(String key) =>
      busy || activating.contains(key) || deleting.contains(key);

  bool installedHas(String tag, int assetId) => installed.any(
    (entry) =>
        entry.manifest.releaseTag == tag && entry.manifest.assetId == assetId,
  );

  CoreVersionsPageState copyWith({
    CoreDownloadCapability? capability,
    String? bundledVersion,
    List<CoreInstalledVersion>? installed,
    Object? activeInstallationId = _notProvided,
    List<CoreRelease>? available,
    bool? catalogLoaded,
    bool? catalogStale,
    bool? catalogRefreshing,
    Object? catalogFailure,
    bool clearCatalogFailure = false,
    bool? loading,
    bool? failed,
    Object? failure,
    Object? downloadingTag = _notProvided,
    Object? downloadProgress = _notProvided,
    bool? verifying,
    Set<String>? activating,
    Set<String>? deleting,
    Map<String, String>? errors,
  }) => CoreVersionsPageState(
    capability: capability ?? this.capability,
    bundledVersion: bundledVersion ?? this.bundledVersion,
    installed: installed ?? this.installed,
    activeInstallationId: identical(activeInstallationId, _notProvided)
        ? this.activeInstallationId
        : activeInstallationId as String?,
    available: available ?? this.available,
    catalogLoaded: catalogLoaded ?? this.catalogLoaded,
    catalogStale: catalogStale ?? this.catalogStale,
    catalogRefreshing: catalogRefreshing ?? this.catalogRefreshing,
    catalogFailure: clearCatalogFailure
        ? null
        : catalogFailure ?? this.catalogFailure,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    failure: failed == false ? null : failure ?? this.failure,
    downloadingTag: identical(downloadingTag, _notProvided)
        ? this.downloadingTag
        : downloadingTag as String?,
    downloadProgress: identical(downloadProgress, _notProvided)
        ? this.downloadProgress
        : downloadProgress as double?,
    verifying: verifying ?? this.verifying,
    activating: activating ?? this.activating,
    deleting: deleting ?? this.deleting,
    errors: errors ?? this.errors,
  );
}

/// Drives the core version screen: what this build may do, what is
/// installed, what the catalog offers, and the one selected version.
/// Nothing here starts or stops the core; the selection applies on the next
/// connection, exactly like the bundled core.
class CoreVersionsController extends PageCubit<CoreVersionsPageState> {
  CoreVersionsController({
    CoreVersionService? service,
    Future<String> Function()? bundledVersion,
  }) : service = service ?? CoreVersionService(),
       _bundledVersion = bundledVersion ?? AppHostApi().xrayVersion,
       super(
         CoreVersionsPageState(
           capability: (service ?? CoreVersionService()).capability(),
         ),
       ) {
    load();
  }

  final CoreVersionService service;
  final Future<String> Function() _bundledVersion;

  String unavailableReasonLabel(AppLocalizations l) =>
      switch (state.capability.unavailableReason) {
        CoreDownloadUnavailableReason.buildDisabled =>
          l.coreVersionsUnavailableBuild,
        CoreDownloadUnavailableReason.unsupportedAbi =>
          l.coreVersionsUnavailableAbi,
        CoreDownloadUnavailableReason.androidPlayDistribution ||
        CoreDownloadUnavailableReason.windowsMsixDistribution =>
          l.coreVersionsUnavailableChannel,
        _ => l.coreVersionsUnavailablePlatform,
      };

  Future<void> load({bool refreshCatalog = false}) async {
    emit(state.copyWith(loading: true, failed: false));
    emit(state.copyWith(capability: service.capability()));
    try {
      await _refreshSelection();
      if (isPageActive) emit(state.copyWith(loading: false));
    } catch (error) {
      if (isPageActive) {
        emit(state.copyWith(loading: false, failed: true, failure: error));
      }
    }
    unawaited(_loadBundledVersion());
    if (state.capability.enabled) {
      await _loadCatalog(refresh: refreshCatalog);
    } else if (isPageActive) {
      emit(state.copyWith(clearCatalogFailure: true));
    }
  }

  Future<void> refreshCatalog() async {
    if (state.catalogRefreshing || !state.capability.enabled) return;
    emit(state.copyWith(catalogRefreshing: true));
    await _loadCatalog(refresh: true);
    if (isPageActive) emit(state.copyWith(catalogRefreshing: false));
  }

  Future<void> _loadBundledVersion() async {
    try {
      final version = await _bundledVersion();
      if (version.isNotEmpty && isPageActive) {
        emit(state.copyWith(bundledVersion: version));
      }
    } catch (_) {
      // The bundled version is decoration; the screen works without it.
    }
  }

  Future<void> _loadCatalog({required bool refresh}) async {
    try {
      final result = await service.catalog(refresh: refresh);
      if (!isPageActive) return;
      emit(
        state.copyWith(
          available: result.releases,
          catalogLoaded: true,
          catalogStale: result.stale,
          clearCatalogFailure: true,
        ),
      );
    } catch (error) {
      if (isPageActive) {
        emit(state.copyWith(catalogFailure: error));
      }
    }
  }

  Future<void> download(BuildContext context, CoreRelease release) async {
    if (state.busy) return;
    final asset = release.assetNamed(state.capability.assetName ?? '');
    if (asset == null) return;
    final l = AppLocalizations.of(context)!;
    _setError(release.tag, null);
    emit(
      state.copyWith(
        downloadingTag: release.tag,
        downloadProgress: null,
        verifying: false,
      ),
    );
    try {
      await service.install(
        release,
        onProgress: (received, total) {
          if (!isPageActive) return;
          if (total > 0) {
            emit(
              state.copyWith(
                downloadProgress: received / total,
                verifying: received >= total,
              ),
            );
          }
        },
      );
      await _refreshSelection();
    } catch (error) {
      _setError(release.tag, coreVersionFailureMessage(l, error));
    } finally {
      if (isPageActive) {
        emit(
          state.copyWith(
            downloadingTag: null,
            downloadProgress: null,
            verifying: false,
          ),
        );
      }
    }
  }

  Future<void> activate(BuildContext context, String installationId) =>
      _select(context, installationId);

  Future<void> returnToBundled(BuildContext context) => _select(context, null);

  Future<void> _select(BuildContext context, String? installationId) async {
    final key = installationId ?? bundledErrorKey;
    final busy =
        state.busy ||
        (installationId == null
            ? state.bundledActive
            : state.activeInstallationId == installationId);
    if (busy) return;
    final l = AppLocalizations.of(context)!;
    _setError(key, null);
    emit(state.copyWith(activating: {...state.activating, key}));
    try {
      await service.select(installationId);
      await _refreshSelection();
    } catch (error) {
      _setError(
        key,
        appFailureMessage(l, error, operation: l.coreVersionsActivateError),
      );
    } finally {
      final activating = {...state.activating}..remove(key);
      if (isPageActive) emit(state.copyWith(activating: activating));
    }
  }

  Future<void> delete(BuildContext context, String installationId) async {
    if (state.busy || state.activeInstallationId == installationId) return;
    final l = AppLocalizations.of(context)!;
    emit(state.copyWith(deleting: {...state.deleting, installationId}));
    try {
      await service.remove(installationId);
      await _refreshSelection();
    } catch (error) {
      _setError(installationId, coreVersionFailureMessage(l, error));
    } finally {
      final deleting = {...state.deleting}..remove(installationId);
      if (isPageActive) emit(state.copyWith(deleting: deleting));
    }
  }

  Future<void> _refreshSelection() async {
    final installed = await service.installed();
    final active = await service.activeInstallationId();
    if (isPageActive) {
      emit(state.copyWith(installed: installed, activeInstallationId: active));
    }
  }

  void _setError(String key, String? message) {
    if (!isPageActive) return;
    final errors = {...state.errors};
    if (message == null) {
      errors.remove(key);
    } else {
      errors[key] = message;
    }
    emit(state.copyWith(errors: errors));
  }

  static const bundledErrorKey = 'bundled';
}

/// Turns installer and catalog failures into the approved screen copy.
String coreVersionFailureMessage(AppLocalizations l, Object? error) {
  if (error is AppFailure) {
    switch (error.code) {
      case 'coreDownloadsDisabled':
        return l.coreVersionsUnavailableBuild;
      case 'coreAssetDigestMismatch':
        return l.coreVersionsIntegrityError;
      case 'coreVersionActive':
        return l.coreVersionsDeleteActiveError;
      case 'catalogUnavailable':
        return l.coreVersionsCatalogOffline;
      case 'coreAssetDigestMissing':
      case 'coreArchiveUnexpectedContent':
      case 'coreArchiveInvalid':
      case 'coreArchiveTooManyEntries':
      case 'coreArchiveEntryTooLarge':
      case 'coreArchiveTooLarge':
      case 'coreArchiveUnsafePath':
      case 'coreArchiveSymlink':
      case 'coreInstallFailed':
        return l.coreVersionsInstallError;
    }
  }
  return appFailureMessage(l, error);
}

/// Compact asset size for the Available rows, for example `46.1 MB`.
String formatReleaseSize(int bytes) {
  const mib = 1024 * 1024;
  if (bytes >= mib) {
    return '${(bytes / mib).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
