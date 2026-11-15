import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/connect/inbound_mode.dart';
import 'package:onexray/pages/theme/theme.dart';
import 'package:onexray/service/settings/language/locale.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light,
  localizationsDelegates: AppLocalePolicy.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (_, child) => ShadTheme(
    data: AppTheme.shad(Brightness.light),
    child: ShadToaster(child: child!),
  ),
  home: Scaffold(
    body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
  ),
);

Widget _card({
  bool tunEnabled = false,
  bool socksEnabled = false,
  int socksPort = 10808,
  bool systemProxyEnabled = false,
  bool keepConfigInbounds = false,
  bool enabled = true,
  bool systemProxyVisible = true,
  bool systemProxyLive = true,
  List<bool>? proxyChanges,
}) => InboundModeCard(
  tunEnabled: tunEnabled,
  socksEnabled: socksEnabled,
  socksPort: socksPort,
  systemProxyEnabled: systemProxyEnabled,
  keepConfigInbounds: keepConfigInbounds,
  enabled: enabled,
  systemProxyVisible: systemProxyVisible,
  systemProxyLive: systemProxyLive,
  onSystemProxyChanged: (value) => proxyChanges?.add(value),
);

final _header = find.byKey(const ValueKey('connection-inbound-mode-header'));
final _systemSwitch = find.byKey(
  const ValueKey('connection-system-proxy-switch'),
);

AppLocalizations _localizations(WidgetTester tester) =>
    AppLocalizations.of(tester.element(_header))!;

void main() {
  testWidgets('the card starts expanded and collapses to a summary', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      _app(_card(tunEnabled: true, socksEnabled: true, systemProxyEnabled: true)),
    );
    await tester.pumpAndSettle();
    final l = _localizations(tester);

    expect(find.byKey(const ValueKey('connection-tun-switch')), findsOneWidget);
    expect(_systemSwitch, findsOneWidget);
    expect(
      find.byKey(const ValueKey('connection-socks-port')),
      findsOneWidget,
    );

    await tester.tap(_header);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connection-tun-switch')), findsNothing);
    expect(_systemSwitch, findsNothing);
    expect(
      find.text(
        '${l.connectionTunMode} · '
        '${l.connectionInboundSummaryPort(10808)} · '
        '${l.connectionSystemProxyMode}',
      ),
      findsOneWidget,
    );

    await tester.tap(_header);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connection-tun-switch')), findsOneWidget);
    expect(_systemSwitch, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty summary states that no ingress is managed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_card(systemProxyVisible: false, systemProxyLive: false)),
    );
    await tester.pumpAndSettle();
    final l = _localizations(tester);

    await tester.tap(_header);
    await tester.pumpAndSettle();

    expect(find.text(l.connectionInboundSummaryNone), findsOneWidget);
  });

  testWidgets('the system proxy row only appears on desktop', (tester) async {
    await tester.pumpWidget(_app(_card(systemProxyVisible: false)));
    await tester.pumpAndSettle();

    expect(_systemSwitch, findsNothing);
    // The other ingress switches stay untouched.
    expect(
      find.byKey(const ValueKey('connection-socks-switch')),
      findsOneWidget,
    );
  });

  testWidgets('the stored value stays visible but inert while disconnected', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _app(
        _card(
          systemProxyEnabled: true,
          systemProxyLive: false,
          proxyChanges: changes,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final control = tester.widget<ShadSwitch>(
      find.descendant(of: _systemSwitch, matching: find.byType(ShadSwitch)),
    );
    expect(control.value, isTrue, reason: 'the stored intent stays visible');
    expect(control.enabled, isFalse);
    expect(changes, isEmpty);
  });

  testWidgets('a live switch reports taps', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _app(_card(systemProxyLive: true, proxyChanges: changes)),
    );
    await tester.pumpAndSettle();

    await tester.tap(_systemSwitch);
    await tester.pumpAndSettle();

    expect(changes, [true]);
    expect(tester.takeException(), isNull);
  });
}
