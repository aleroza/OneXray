import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/advanced/xray/core_versions/controller.dart';
import 'package:onexray/pages/advanced/xray/core_versions/page.dart';
import 'package:onexray/pages/theme/theme.dart';
import 'package:onexray/service/advanced/xray/core_version/service.dart';
import 'package:onexray/service/advanced/xray/core_version/storage.dart';
import 'package:onexray/service/settings/language/locale.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../../../support/test_directory.dart';

const _linuxAsset = 'libxray-linux-x64.zip';

List<int> linuxZip() => ZipEncoder().encode(
  Archive()
    ..add(ArchiveFile.string('libxray-linux-x64/xray', 'core-binary'))
    ..add(ArchiveFile.string('libxray-linux-x64/libXray.so', 'library'))
    ..add(ArchiveFile.string('libxray-linux-x64/libXray.h', 'header')),
);

String githubBody() => jsonEncode([
  {
    'tag_name': 'v26.11.9',
    'published_at': '2026-11-09T10:00:00Z',
    'prerelease': false,
    'assets': [
      {
        'id': 42,
        'name': _linuxAsset,
        'size': 1234,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url': 'https://example.invalid/$_linuxAsset',
      },
    ],
  },
]);

Widget app(Widget child) => MaterialApp(
  theme: AppTheme.light,
  localizationsDelegates: AppLocalePolicy.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (_, child) =>
      ShadTheme(data: AppTheme.shad(Brightness.light), child: child!),
  home: child,
);

void main() {
  final preferences = InMemorySharedPreferencesAsync.empty();
  setUpAll(() => SharedPreferencesAsyncPlatform.instance = preferences);
  setUp(() => SharedPreferencesAsync().clear());

  late CoreVersionStorage storage;

  Future<CoreVersionsController> buildController(
    WidgetTester tester, {
    required bool enabled,
  }) async {
    late CoreVersionsController controller;
    await tester.runAsync(() async {
      storage = CoreVersionStorage(
        await createTestDirectory('core-versions-page'),
      );
      controller = CoreVersionsController(
        service: CoreVersionService(
          openStorage: () async => storage,
          capability: () => enabled
              ? const CoreDownloadCapability.enabled(
                  platform: CorePlatform.linux,
                  abi: CoreAbi.x64,
                  assetName: _linuxAsset,
                )
              : const CoreDownloadCapability.disabled(
                  CoreDownloadUnavailableReason.androidPlayDistribution,
                ),
          catalogAssetName: () => _linuxAsset,
          catalogRequest: (uri, headers) async =>
              (statusCode: 200, etag: '"page"', body: githubBody()),
        ),
        bundledVersion: () async => 'Xray 26.11.9',
      );
      addTearDown(controller.close);
      for (
        var attempt = 0;
        attempt < 500 &&
            (controller.state.loading ||
                (enabled &&
                    !controller.state.catalogLoaded &&
                    controller.state.catalogFailure == null));
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    return controller;
  }

  Future<AppLocalizations> pumpPage(
    WidgetTester tester,
    CoreVersionsController controller,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      app(CoreVersionsPage(createController: () => controller)),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(CoreVersionsPage)))!;
  }

  testWidgets('an enabled build offers the catalog version', (tester) async {
    final controller = await buildController(tester, enabled: true);
    final l = await pumpPage(tester, controller);

    expect(find.text(l.coreVersionsBundledSection), findsOneWidget);
    expect(find.text(l.coreVersionsInstalledSection), findsOneWidget);
    expect(find.text(l.coreVersionsAvailableSection), findsOneWidget);
    expect(find.text('v26.11.9'), findsOneWidget);
    expect(find.byTooltip(l.prototypeDownload), findsOneWidget);
    expect(find.text(l.coreVersionsNoInstalled), findsOneWidget);
    expect(find.text('Xray 26.11.9'), findsOneWidget);
  });

  testWidgets('a disabled build explains itself and hides the actions', (
    tester,
  ) async {
    final controller = await buildController(tester, enabled: false);
    final l = await pumpPage(tester, controller);

    expect(find.text(l.coreVersionsUnavailableChannel), findsOneWidget);
    expect(find.text(l.coreVersionsBundledSection), findsOneWidget);
    expect(find.text(l.coreVersionsAvailableSection), findsNothing);
    expect(find.byTooltip(l.prototypeDownload), findsNothing);
    expect(find.byTooltip(l.coreVersionsActivate), findsNothing);
    expect(find.byTooltip(l.coreVersionsRefreshCatalog), findsNothing);
  });

  testWidgets('installed versions render with the verified digest note', (
    tester,
  ) async {
    final controller = await buildController(tester, enabled: true);
    final l = await pumpPage(tester, controller);
    await tester.runAsync(() async {
      final directory = storage.versionDirectory('v26.11.9-42');
      await directory.create(recursive: true);
      await storage.writeManifest(
        directory,
        CoreVersionManifest(
          releaseTag: 'v26.11.9',
          assetId: 42,
          assetName: _linuxAsset,
          assetSize: 1234,
          expectedSha256: 'a' * 64,
          installedSha256: 'b' * 64,
          platform: 'linux',
          abi: 'x64',
          installedAt: DateTime.utc(2026, 11, 10),
          installDir: directory.path,
        ),
      );
      await controller.load();
    });
    await tester.pumpAndSettle();

    expect(find.text('v26.11.9'), findsOneWidget);
    expect(find.text(l.coreVersionsVerified), findsOneWidget);
    expect(find.text(l.coreVersionsNoInstalled), findsNothing);
    // The installed asset leaves the Available list; only Activate and
    // Delete remain, and the row is not marked Active while bundled is on.
    expect(find.byTooltip(l.prototypeDownload), findsNothing);
    expect(find.byTooltip(l.coreVersionsActivate), findsOneWidget);
    // Bundled still owns the Active mark; the installed row offers Activate.
    expect(find.text(l.coreVersionsActive), findsOneWidget);
  });
}
