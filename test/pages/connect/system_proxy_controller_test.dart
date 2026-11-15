import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/db/database/database.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/connect/controller.dart';
import 'package:onexray/pages/theme/theme.dart';
import 'package:onexray/service/advanced/platform_policy.dart';
import 'package:onexray/service/connect/coordinator.dart';
import 'package:onexray/service/connect/runtime.dart';
import 'package:onexray/service/settings/language/locale.dart';
import 'package:onexray/service/shared/share/configuration_transfer.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// One saved change with the reconnect-relevant flags the controller chose.
class _Applied {
  const _Applied(this.next, this.affectsRuntime, this.allowReconnect);

  final ConnectionConfiguration next;
  final bool affectsRuntime;
  final bool allowReconnect;
}

/// Records applied configurations instead of touching the database compile
/// path; the state stays exactly where each test put it.
class _FakeCoordinator extends ConnectionCoordinator {
  _FakeCoordinator()
    : super(database: AppDatabase.forTesting(NativeDatabase.memory()));

  ConnectionConfiguration saved = ConnectionConfiguration();
  final applied = <_Applied>[];

  @override
  Future<ConnectionConfiguration> get configuration async => saved;

  @override
  Future<void> apply(
    ConnectionConfiguration next, {
    bool connect = false,
    bool disconnect = false,
    bool affectsRuntime = true,
    bool allowReconnect = true,
    String? expectedConfiguration,
    Future<void> Function()? writeAssets,
    Future<void> Function()? validateAssets,
    ConfigurationImportDraft? imported,
    PrepareConnection? prepare,
  }) async {
    applied.add(_Applied(next, affectsRuntime, allowReconnect));
    saved = next;
  }
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light,
  localizationsDelegates: AppLocalePolicy.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (_, child) => ShadTheme(
    data: AppTheme.shad(Brightness.light),
    child: ShadToaster(child: child!),
  ),
  home: child,
);

ConnectionConfiguration _configuration({
  bool socksEnabled = false,
  bool systemProxyEnabled = false,
}) => ConnectionConfiguration(
  policy: PlatformPolicy.fromJson({
    'inbound': {'socksEnabled': socksEnabled},
    'systemProxy': {'enabled': systemProxyEnabled},
  }),
);

void main() {
  late AppDatabase db;
  late _FakeCoordinator coordinator;
  late ConnectController controller;
  late List<int> appliedPorts;
  late List<String> removals;
  late String? applyFailure;
  late String? removeFailure;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    coordinator = _FakeCoordinator();
    appliedPorts = [];
    removals = [];
    applyFailure = null;
    removeFailure = null;
    controller = ConnectController(
      database: db,
      coordinator: coordinator,
      applySystemProxy: (port) async {
        appliedPorts.add(port);
        return applyFailure;
      },
      removeSystemProxy: () async {
        removals.add('remove');
        return removeFailure;
      },
    );
    addTearDown(controller.close);
    addTearDown(coordinator.dispose);
    addTearDown(db.close);
  });

  Future<bool> toggle(WidgetTester tester, bool enabled) async {
    late bool result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await controller.changeSystemProxyEnabled(
                  context,
                  enabled,
                );
              },
              child: const Text('toggle'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();
    return result;
  }

  Future<void> dismissToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  AppLocalizations localizations(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.text('toggle')))!;

  testWidgets('while disconnected enabling only stores the intent and opens '
      'the local port', (tester) async {
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.disconnected,
    );
    coordinator.saved = _configuration();
    controller.configuration = coordinator.saved;

    expect(await toggle(tester, true), isTrue);

    expect(appliedPorts, isEmpty, reason: 'nothing is connected yet');
    expect(coordinator.applied, hasLength(1));
    expect(
      coordinator.applied.single.affectsRuntime,
      isTrue,
      reason: 'opening the local port changes the compiled configuration',
    );
    expect(coordinator.applied.single.allowReconnect, isFalse);
    expect(coordinator.saved.policy.systemProxyEnabled, isTrue);
    expect(coordinator.saved.policy.socksEnabled, isTrue);
    expect(controller.systemProxyEnabled, isTrue);
  });

  testWidgets('a live enable applies on the SOCKS port without a reconnect', (
    tester,
  ) async {
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.connected,
    );
    coordinator.saved = _configuration(socksEnabled: true);
    controller.configuration = coordinator.saved;

    expect(await toggle(tester, true), isTrue);

    expect(find.byType(AlertDialog), findsNothing);
    expect(coordinator.applied.single.affectsRuntime, isFalse);
    expect(coordinator.applied.single.allowReconnect, isFalse);
    expect(appliedPorts, [10808]);
    expect(coordinator.saved.policy.systemProxyEnabled, isTrue);
  });

  testWidgets('a live enable that first opens the port reconnects instead', (
    tester,
  ) async {
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.connected,
    );
    coordinator.saved = _configuration();
    controller.configuration = coordinator.saved;

    late bool result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await controller.changeSystemProxyEnabled(
                  context,
                  true,
                );
              },
              child: const Text('toggle'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();
    expect(find.text('Save and reconnect'), findsOneWidget);
    await tester.tap(find.text('Save and reconnect'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(coordinator.applied.single.affectsRuntime, isTrue);
    expect(coordinator.applied.single.allowReconnect, isTrue);
    expect(
      appliedPorts,
      isEmpty,
      reason: 'the reconnect applies the proxy through the runtime host',
    );
    expect(coordinator.saved.policy.systemProxyEnabled, isTrue);
    expect(coordinator.saved.policy.socksEnabled, isTrue);
  });

  testWidgets('a live failure rolls the stored intent back and explains', (
    tester,
  ) async {
    applyFailure = 'gsettings refused';
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.connected,
    );
    coordinator.saved = _configuration(socksEnabled: true);
    controller.configuration = coordinator.saved;

    expect(await toggle(tester, true), isFalse);

    final l = localizations(tester);
    expect(coordinator.applied, hasLength(2), reason: 'save then revert');
    expect(
      removals,
      ['remove'],
      reason: 'the partially applied OS state is rolled back first',
    );
    expect(coordinator.saved.policy.systemProxyEnabled, isFalse);
    expect(controller.systemProxyEnabled, isFalse);
    expect(
      find.text(l.connectionSystemProxyFailure(applyFailure!)),
      findsOneWidget,
    );
    await dismissToasts(tester);
  });

  testWidgets('a live disable rolls the OS proxy back', (tester) async {
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.connected,
    );
    coordinator.saved = _configuration(
      socksEnabled: true,
      systemProxyEnabled: true,
    );
    controller.configuration = coordinator.saved;

    expect(await toggle(tester, false), isTrue);

    expect(appliedPorts, isEmpty);
    expect(removals, ['remove']);
    expect(coordinator.saved.policy.systemProxyEnabled, isFalse);
  });

  testWidgets('a failing disable keeps the stored off state and explains', (
    tester,
  ) async {
    removeFailure = 'registry locked';
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.connected,
    );
    coordinator.saved = _configuration(
      socksEnabled: true,
      systemProxyEnabled: true,
    );
    controller.configuration = coordinator.saved;

    expect(await toggle(tester, false), isFalse);

    expect(coordinator.applied, hasLength(1), reason: 'no revert of an off');
    expect(coordinator.saved.policy.systemProxyEnabled, isFalse);
    final l = localizations(tester);
    expect(
      find.text(l.connectionSystemProxyFailure(removeFailure!)),
      findsOneWidget,
    );
    await dismissToasts(tester);
  });

  testWidgets('the same stored value changes nothing', (tester) async {
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.disconnected,
    );
    coordinator.saved = _configuration(
      socksEnabled: true,
      systemProxyEnabled: true,
    );
    controller.configuration = coordinator.saved;

    expect(await toggle(tester, true), isTrue);

    expect(coordinator.applied, isEmpty);
  });

  testWidgets('closing the local port through changeInbound drops the proxy', (
    tester,
  ) async {
    coordinator.state.value = const ConnectionView(
      phase: ConnectionPhase.connected,
    );
    coordinator.saved = _configuration(
      socksEnabled: true,
      systemProxyEnabled: true,
    );
    controller.configuration = coordinator.saved;

    late bool result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await controller.changeInbound(
                  context,
                  {'socksEnabled': false},
                  systemProxyEnabled: false,
                  label: 'port',
                );
              },
              child: const Text('close-port'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('close-port'));
    await tester.pumpAndSettle();
    expect(find.text('Save and reconnect'), findsOneWidget);
    await tester.tap(find.text('Save and reconnect'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(coordinator.saved.policy.socksEnabled, isFalse);
    expect(coordinator.saved.policy.systemProxyEnabled, isFalse);
  });
}
