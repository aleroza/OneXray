import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/advanced/xray/core_versions/controller.dart';
import 'package:onexray/pages/connect/dialogs.dart';
import 'package:onexray/pages/shared/widgets/adaptive_dialog.dart';
import 'package:onexray/pages/shared/widgets/button_progress.dart';
import 'package:onexray/pages/shared/widgets/page_app_bar.dart';
import 'package:onexray/pages/shared/widgets/setting_row.dart';
import 'package:onexray/pages/shared/widgets/settings_page.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:onexray/service/shared/failure.dart';
import 'package:onexray/pages/theme/color.dart';
import 'package:onexray/pages/theme/font.dart';
import 'package:onexray/pages/theme/layout.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Bundled, installed and downloadable Xray core versions. A selection here
/// is applied when the core starts; nothing on this page restarts anything.
class CoreVersionsPage extends StatelessWidget {
  final CoreVersionsController Function()? createController;

  const CoreVersionsPage({super.key, this.createController});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => createController?.call() ?? CoreVersionsController(),
    child: BlocBuilder<CoreVersionsController, CoreVersionsPageState>(
      builder: (context, state) {
        final controller = context.read<CoreVersionsController>();
        final l = AppLocalizations.of(context)!;
        final mobile =
            MediaQuery.sizeOf(context).width <= AppLayout.mobileBreakpoint;
        final gutter = mobile ? AppSpacing.mobilePage : AppSpacing.page;
        return Scaffold(
          appBar: PageAppBar(
            title: Text(l.coreVersionsTitle),
            actions: [
              if (state.capability.enabled)
                IconButton(
                  tooltip: l.coreVersionsRefreshCatalog,
                  onPressed: state.catalogRefreshing
                      ? null
                      : () => controller.refreshCatalog(),
                  icon: state.catalogRefreshing
                      ? const ButtonProgressIndicator()
                      : const Icon(LucideIcons.refreshCw, size: 19),
                ),
            ],
          ),
          body: SafeArea(
            child: SettingsPageScroll(
              padding: EdgeInsetsDirectional.fromSTEB(gutter, 20, gutter, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 20,
                children: [
                  _bundledSection(context, controller, state),
                  if (state.capability.enabled) ...[
                    _installedSection(context, controller, state),
                    _availableSection(context, controller, state),
                  ] else
                    ShadAlert(
                      icon: const Icon(LucideIcons.circleAlert, size: 19),
                      description: Text(controller.unavailableReasonLabel(l)),
                    ),
                  if (state.failed)
                    ShadAlert.destructive(
                      description: SelectableText(
                        appFailureMessage(l, state.failure),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _bundledSection(
    BuildContext context,
    CoreVersionsController controller,
    CoreVersionsPageState state,
  ) {
    final l = AppLocalizations.of(context)!;
    return SettingSection(
      title: l.coreVersionsBundledSection,
      description: l.coreVersionsBundledNote,
      icon: LucideIcons.package,
      padding: EdgeInsets.zero,
      children: [
        SettingRow(
          title: l.prototypeXrayCore,
          value: state.bundledVersion,
          valueTextDirection: TextDirection.ltr,
          titleTrailing: state.bundledActive
              ? _activeChip(context, l.coreVersionsActive)
              : null,
        ),
        if (state.capability.enabled && !state.bundledActive)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      state.operationBusy(
                        CoreVersionsController.bundledErrorKey,
                      )
                      ? null
                      : () => controller.returnToBundled(context),
                  icon:
                      state.operationBusy(
                        CoreVersionsController.bundledErrorKey,
                      )
                      ? const ButtonProgressIndicator(size: 15)
                      : const Icon(LucideIcons.undo2, size: 16),
                  label: Text(l.coreVersionsReturnToBundled),
                ),
              ],
            ),
          ),
        if (state.errors[CoreVersionsController.bundledErrorKey] != null)
          _error(
            context,
            state.errors[CoreVersionsController.bundledErrorKey]!,
          ),
      ],
    );
  }

  Widget _installedSection(
    BuildContext context,
    CoreVersionsController controller,
    CoreVersionsPageState state,
  ) {
    final l = AppLocalizations.of(context)!;
    return SettingSection(
      title: l.coreVersionsInstalledSection,
      icon: LucideIcons.download,
      padding: EdgeInsets.zero,
      children: [
        if (state.installed.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              l.coreVersionsNoInstalled,
              style: AppTypography.supporting.copyWith(
                color: ColorManager.palette(context).mutedForeground,
              ),
            ),
          ),
        for (final entry in state.installed)
          _installedRow(context, controller, state, entry),
        for (final entry in state.installed)
          if (state.errors[entry.installationId] != null)
            _error(context, state.errors[entry.installationId]!),
      ],
    );
  }

  Widget _installedRow(
    BuildContext context,
    CoreVersionsController controller,
    CoreVersionsPageState state,
    CoreInstalledVersion entry,
  ) {
    final l = AppLocalizations.of(context)!;
    final id = entry.installationId;
    final active = state.activeInstallationId == id;
    final busy = state.operationBusy(id);
    return SettingRow(
      title: entry.manifest.releaseTag,
      titleTextDirection: TextDirection.ltr,
      subtitle: entry.manifest.installedSha256 == null
          ? null
          : l.coreVersionsVerified,
      titleTrailing: active ? _activeChip(context, l.coreVersionsActive) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!active)
            IconButton(
              tooltip: l.coreVersionsActivate,
              onPressed: busy ? null : () => controller.activate(context, id),
              icon: state.activating.contains(id)
                  ? const ButtonProgressIndicator(size: 15)
                  : const Icon(LucideIcons.check, size: 18),
            ),
          IconButton(
            tooltip: l.prototypeDelete,
            onPressed: active || busy
                ? null
                : () => _confirmDelete(context, controller, id),
            icon: state.deleting.contains(id)
                ? const ButtonProgressIndicator(size: 15)
                : const Icon(LucideIcons.trash2, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _availableSection(
    BuildContext context,
    CoreVersionsController controller,
    CoreVersionsPageState state,
  ) {
    final l = AppLocalizations.of(context)!;
    final palette = ColorManager.palette(context);
    final releases = [
      for (final release in state.available)
        if (release.assetNamed(state.capability.assetName ?? '') != null &&
            !state.installedHas(
              release.tag,
              release.assetNamed(state.capability.assetName ?? '')!.id,
            ))
          release,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        SettingSection(
          title: l.coreVersionsAvailableSection,
          icon: LucideIcons.cloud,
          padding: EdgeInsets.zero,
          children: [
            if (!state.catalogLoaded && !state.loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l.coreVersionsCatalogOffline,
                  style: AppTypography.supporting.copyWith(
                    color: palette.mutedForeground,
                  ),
                ),
              ),
            for (final release in releases)
              _availableRow(context, controller, state, release),
            for (final release in releases)
              if (state.errors[release.tag] != null)
                _error(context, state.errors[release.tag]!),
          ],
        ),
        if (state.catalogStale)
          ShadAlert(
            icon: const Icon(LucideIcons.info, size: 19),
            description: Text(l.coreVersionsStaleNotice),
          ),
        if (state.catalogFailure != null)
          ShadAlert.destructive(
            description: SelectableText(
              coreVersionFailureMessage(l, state.catalogFailure),
            ),
          ),
      ],
    );
  }

  Widget _availableRow(
    BuildContext context,
    CoreVersionsController controller,
    CoreVersionsPageState state,
    CoreRelease release,
  ) {
    final l = AppLocalizations.of(context)!;
    final asset = release.assetNamed(state.capability.assetName ?? '')!;
    final downloading = state.downloadingTag == release.tag;
    final busy = state.busy;
    final progress = downloading ? state.downloadProgress : null;
    final value = !downloading
        ? null
        : state.verifying
        ? l.coreVersionsVerifying
        : progress == null
        ? l.coreVersionsDownloading
        : '${l.coreVersionsDownloading} ${(progress * 100).clamp(0, 100).round()}%';
    return SettingRow(
      title: release.tag,
      titleTextDirection: TextDirection.ltr,
      subtitle: formatReleaseSize(asset.size),
      value: value,
      valueTextDirection: TextDirection.ltr,
      trailing: IconButton(
        tooltip: l.prototypeDownload,
        onPressed: busy ? null : () => controller.download(context, release),
        icon: downloading
            ? const ButtonProgressIndicator(size: 15)
            : const Icon(LucideIcons.download, size: 18),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    CoreVersionsController controller,
    String installationId,
  ) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showAppDialog<bool>(
      context,
      (dialogContext) => AppDialog(
        title: l.prototypeDelete,
        subtitle: installationId,
        expandLastAction: false,
        body: ConnectCallout(
          icon: LucideIcons.circleAlert,
          text: l.coreVersionsDeleteQuestion,
          warning: true,
        ),
        actions: [
          ConnectDialogButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            label: l.prototypeCancel,
            secondary: true,
          ),
          ConnectDialogButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            label: l.prototypeDelete,
            icon: LucideIcons.trash2,
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await controller.delete(context, installationId);
    }
  }

  Widget _activeChip(BuildContext context, String label) => Text(
    label,
    style: AppTypography.supporting.copyWith(
      color: Theme.of(context).colorScheme.primary,
    ),
  );

  Widget _error(BuildContext context, String message) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(
      message,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: ColorManager.palette(context).destructive),
    ),
  );
}
