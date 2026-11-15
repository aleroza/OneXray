import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/errors/failure.dart';
import 'package:onexray/core/model/core_download_capability.dart';
import 'package:onexray/core/model/core_release.dart';
import 'package:onexray/core/tools/core_platform.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/advanced/xray/core_versions/controller.dart';
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

CoreAsset assetFor(List<int> zip, {String? digest}) => CoreAsset(
  id: 42,
  name: _linuxAsset,
  size: zip.length,
  digest: 'sha256:${digest ?? sha256.convert(zip)}',
  downloadUrl: 'https://example.invalid/$_linuxAsset',
);

String githubBody(CoreAsset asset) => jsonEncode([
  {
    'tag_name': 'v26.11.9',
    'published_at': '2026-11-09T10:00:00Z',
    'prerelease': false,
    'assets': [asset.toJson()],
  },
]);

Widget screen(Widget child) => MaterialApp(
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
  late List<String> requested;
  late List<int> servedZip;
  late int transportFailures;

  setUp(() async {
    storage = CoreVersionStorage(await createTestDirectory('core-versions-ui'));
    requested = [];
    servedZip = linuxZip();
    transportFailures = 0;
  });

  /// The controller loads asynchronously against real disk; wait until the
  /// first full pass finished instead of guessing a pump count.
  Future<void> settled(CoreVersionsController controller) async {
    for (var attempt = 0; attempt < 500; attempt++) {
      final state = controller.state;
      if (!state.loading &&
          (!state.capability.enabled ||
              state.catalogLoaded ||
              state.catalogFailure != null)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    fail('the controller never finished its first load');
  }

  CoreVersionService serviceFor({
    bool enabled = true,
    String? digest,
    bool failTransport = false,
  }) => CoreVersionService(
    openStorage: () async => storage,
    capability: () => enabled
        ? const CoreDownloadCapability.enabled(
            platform: CorePlatform.linux,
            abi: CoreAbi.x64,
            assetName: _linuxAsset,
          )
        : const CoreDownloadCapability.disabled(
            CoreDownloadUnavailableReason.buildDisabled,
          ),
    catalogAssetName: () => _linuxAsset,
    catalogRequest: (uri, headers) async {
      if (transportFailures > 0) {
        transportFailures -= 1;
        throw const SocketException('offline');
      }
      requested.add(uri.toString());
      return (
        statusCode: 200,
        etag: '"fixture"',
        body: githubBody(assetFor(servedZip, digest: digest)),
      );
    },
    assetDownload: (uri, destination, progress) async {
      await destination.writeAsBytes(servedZip);
      progress?.call(servedZip.length, servedZip.length);
    },
  );

  CoreVersionsController controllerFor({bool enabled = true, String? digest}) =>
      CoreVersionsController(
        service: serviceFor(enabled: enabled, digest: digest),
        bundledVersion: () async => 'Xray 26.11.9',
      );

  Future<(CoreVersionsController, BuildContext, AppLocalizations)> pumpScreen(
    WidgetTester tester, {
    bool enabled = true,
    String? digest,
  }) async {
    BuildContext? captured;
    await tester.pumpWidget(
      screen(
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    // Real disk IO in the initial load needs the real async zone, so the
    // controller is created inside runAsync together with its load().
    late CoreVersionsController controller;
    await tester.runAsync(() async {
      controller = controllerFor(enabled: enabled, digest: digest);
      addTearDown(controller.close);
      await settled(controller);
    });
    return (controller, captured!, AppLocalizations.of(captured!)!);
  }

  CoreRelease releaseOf({String? digest}) => CoreRelease(
    tag: 'v26.11.9',
    publishedAt: DateTime.utc(2026, 11, 9),
    prerelease: false,
    assets: [assetFor(servedZip, digest: digest)],
  );

  test('load reports the bundled core and the enabled catalog', () async {
    final controller = controllerFor();
    addTearDown(controller.close);
    await settled(controller);

    expect(controller.state.capability.enabled, isTrue);
    expect(controller.state.bundledVersion, 'Xray 26.11.9');
    expect(controller.state.bundledActive, isTrue);
    expect(controller.state.available.map((r) => r.tag), ['v26.11.9']);
    expect(controller.state.installed, isEmpty);
    expect(requested, hasLength(1));
  });

  test('a disabled build never asks the network', () async {
    final controller = controllerFor(enabled: false);
    addTearDown(controller.close);
    await settled(controller);

    expect(controller.state.capability.enabled, isFalse);
    expect(
      controller.state.capability.unavailableReason,
      CoreDownloadUnavailableReason.buildDisabled,
    );
    expect(controller.state.available, isEmpty);
    expect(requested, isEmpty);
    expect(controller.state.catalogFailure, isNull);
  });

  test('refresh forces a new catalog request', () async {
    final controller = controllerFor();
    addTearDown(controller.close);
    await settled(controller);
    expect(requested, hasLength(1));
    await controller.refreshCatalog();
    expect(requested, hasLength(2));
  });

  test('a transport failure serves the cache as stale', () async {
    final controller = controllerFor();
    addTearDown(controller.close);
    await settled(controller);
    transportFailures = 1;

    await controller.refreshCatalog();

    expect(controller.state.available, hasLength(1));
    expect(controller.state.catalogStale, isTrue);
    expect(controller.state.catalogFailure, isNull);
    expect(controller.state.catalogRefreshing, isFalse);
  });

  testWidgets('download verifies and publishes, then Activate selects', (
    tester,
  ) async {
    final (controller, context, _) = await pumpScreen(tester);

    await tester.runAsync(() async {
      await settled(controller);
      await controller.download(context, releaseOf());
      expect(controller.state.installed.map((e) => e.installationId), [
        'v26.11.9-42',
      ]);
      expect(controller.state.downloadingTag, isNull);
      expect(controller.state.errors, isEmpty);
      expect(controller.state.bundledActive, isTrue);

      await controller.activate(context, 'v26.11.9-42');
      expect(controller.state.activeInstallationId, 'v26.11.9-42');
      expect(controller.state.bundledActive, isFalse);

      await controller.returnToBundled(context);
      expect(controller.state.activeInstallationId, isNull);
      expect(controller.state.bundledActive, isTrue);
    });
  });

  testWidgets('a digest lie surfaces the integrity message', (tester) async {
    final (controller, context, l) = await pumpScreen(tester, digest: '0' * 64);

    await tester.runAsync(() async {
      await settled(controller);
      await controller.download(context, releaseOf(digest: '0' * 64));
      expect(controller.state.errors['v26.11.9'], l.coreVersionsIntegrityError);
      expect(controller.state.installed, isEmpty);
    });
  });

  testWidgets('deleting the active version is refused, others leave', (
    tester,
  ) async {
    final (controller, context, _) = await pumpScreen(tester);
    await tester.runAsync(() async {
      await settled(controller);
      await controller.download(context, releaseOf());
      await controller.activate(context, 'v26.11.9-42');

      await controller.delete(context, 'v26.11.9-42');
      expect(controller.state.installed, hasLength(1));

      await controller.returnToBundled(context);
      await controller.delete(context, 'v26.11.9-42');
      expect(controller.state.installed, isEmpty);
      expect(controller.state.errors, isEmpty);
    });
  });

  testWidgets('failure codes map to the approved screen copy', (tester) async {
    AppLocalizations? l;
    await tester.pumpWidget(
      screen(
        Builder(
          builder: (context) {
            l = AppLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    final localization = l!;
    expect(
      coreVersionFailureMessage(
        localization,
        const AppFailure(FailureCategory.input, 'coreAssetDigestMismatch'),
      ),
      localization.coreVersionsIntegrityError,
    );
    expect(
      coreVersionFailureMessage(
        localization,
        const AppFailure(FailureCategory.input, 'coreVersionActive'),
      ),
      localization.coreVersionsDeleteActiveError,
    );
    expect(
      coreVersionFailureMessage(
        localization,
        const AppFailure(FailureCategory.network, 'catalogUnavailable'),
      ),
      localization.coreVersionsCatalogOffline,
    );
    expect(
      coreVersionFailureMessage(
        localization,
        const AppFailure(FailureCategory.input, 'coreArchiveInvalid'),
      ),
      localization.coreVersionsInstallError,
    );
  });
}
