import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/system_proxy/command_runner.dart';
import 'package:onexray/core/system_proxy/macos_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';

const _tool = '/usr/sbin/networksetup';

class _FakeOs {
  _FakeOs(this.reads);

  /// Responses keyed by the joined arguments, e.g. `-getwebproxy Wi-Fi`.
  final Map<String, String> reads;
  final commands = <String>[];

  Future<SystemProxyCommandResult> call(
    String executable,
    List<String> arguments,
  ) async {
    expect(executable, _tool);
    final line = arguments.join(' ');
    commands.add('$executable $line');
    final read = reads[line];
    if (read != null) {
      return SystemProxyCommandResult(exitCode: 0, output: read);
    }
    if (line.startsWith('-get') || line.startsWith('-listall')) {
      return const SystemProxyCommandResult(
        exitCode: 1,
        errorText: 'unscripted read',
      );
    }
    return const SystemProxyCommandResult(exitCode: 0);
  }
}

String _serviceState({
  bool enabled = false,
  String server = '',
  String port = '0',
}) =>
    'Enabled: ${enabled ? 'Yes' : 'No'}\n'
    'Server: $server\n'
    'Port: $port\n'
    'Authenticated Proxy Enabled: 0';

String _bypassOutput(String service, List<String> domains) => domains.isEmpty
    ? 'Proxy Bypass Domains for "$service":\n'
          "There aren't any bypass domains set.\n"
    : 'Proxy Bypass Domains for "$service":\n${domains.join('\n')}\n';

Map<String, String> _network({
  List<String> domains = const [],
  bool webEnabled = false,
  String webServer = '',
  String webPort = '0',
}) => {
  '-listallnetworkservices':
      'An asterisk (*) denotes that a network service is disabled.\n'
      'Wi-Fi\n'
      'USB 10/100 LAN\n'
      '*Thunderbolt Bridge\n',
  for (final service in ['Wi-Fi', 'USB 10/100 LAN'])
    '-getwebproxy $service': _serviceState(
      enabled: webEnabled,
      server: webServer,
      port: webPort,
    ),
  for (final service in ['Wi-Fi', 'USB 10/100 LAN'])
    '-getsecurewebproxy $service': _serviceState(),
  for (final service in ['Wi-Fi', 'USB 10/100 LAN'])
    '-getsocksfirewallproxy $service': _serviceState(),
  for (final service in ['Wi-Fi', 'USB 10/100 LAN'])
    '-getproxybypassdomains $service': _bypassOutput(service, domains),
};

MacSystemProxyBackend backend(_FakeOs os) =>
    MacSystemProxyBackend(run: os.call, tool: _tool);

void main() {
  test('read skips disabled services and diagnostic bypass lines', () async {
    final os = _FakeOs(
      _network(
        domains: ['.corp'],
        webEnabled: true,
        webServer: '127.0.0.1',
        webPort: '10808',
      ),
    );

    final state = await backend(os).read();

    expect(state.values['services'], 'Wi-Fi\nUSB 10/100 LAN');
    expect(state.enabled, isTrue);
    expect(state.pointsAtLocalProxy(10808), isTrue);
    expect(state.bypass, ['.corp']);
    expect(state.values['Thunderbolt Bridge|web|enabled'], isNull);
  });

  test('apply sets every kind, then bypass, then turns states on', () async {
    final os = _FakeOs(_network(domains: ['.corp']));
    final proxy = backend(os);
    final before = await proxy.read();
    os.commands.clear();

    await proxy.apply(port: 10808, before: before);

    expect(os.commands, [
      '$_tool -setwebproxy Wi-Fi 127.0.0.1 10808',
      '$_tool -setsecurewebproxy Wi-Fi 127.0.0.1 10808',
      '$_tool -setsocksfirewallproxy Wi-Fi 127.0.0.1 10808',
      '$_tool -setproxybypassdomains Wi-Fi .corp localhost 127.0.0.1 ::1',
      '$_tool -setwebproxystate Wi-Fi on',
      '$_tool -setsecurewebproxystate Wi-Fi on',
      '$_tool -setsocksfirewallproxystate Wi-Fi on',
      '$_tool -setwebproxy USB 10/100 LAN 127.0.0.1 10808',
      '$_tool -setsecurewebproxy USB 10/100 LAN 127.0.0.1 10808',
      '$_tool -setsocksfirewallproxy USB 10/100 LAN 127.0.0.1 10808',
      '$_tool -setproxybypassdomains USB 10/100 LAN localhost 127.0.0.1 ::1',
      '$_tool -setwebproxystate USB 10/100 LAN on',
      '$_tool -setsecurewebproxystate USB 10/100 LAN on',
      '$_tool -setsocksfirewallproxystate USB 10/100 LAN on',
    ]);
  });

  test('restore returns states, servers and bypass lists byte for byte',
      () async {
    final os = _FakeOs(
      _network(
        domains: ['*.internal'],
        webEnabled: true,
        webServer: 'proxy.example',
        webPort: '3128',
      ),
    );
    final proxy = backend(os);
    final snapshot = await proxy.read();
    await proxy.apply(port: 10808, before: snapshot);
    os.commands.clear();

    await proxy.restore(snapshot);

    final expected = <String>[];
    for (final service in ['Wi-Fi', 'USB 10/100 LAN']) {
      expected.addAll([
        '$_tool -setwebproxy $service proxy.example 3128',
        '$_tool -setwebproxystate $service on',
        '$_tool -setsecurewebproxystate $service off',
        '$_tool -setsocksfirewallproxystate $service off',
        '$_tool -setproxybypassdomains $service *.internal',
      ]);
    }
    expect(os.commands, expected);
  });

  test('a configured but disabled proxy keeps its server and stays off',
      () async {
    final os = _FakeOs({
      ..._network(),
      '-getwebproxy Wi-Fi':
          _serviceState(enabled: false, server: '10.0.0.5', port: '8080'),
    });
    final proxy = backend(os);
    final snapshot = await proxy.read();
    await proxy.apply(port: 10808, before: snapshot);
    os.commands.clear();

    await proxy.restore(snapshot);

    expect(
      os.commands.where(
        (line) =>
            line.contains(' Wi-Fi') &&
            !line.contains('secureweb') &&
            !line.contains('socksfirewall') &&
            !line.contains('bypassdomains'),
      ),
      [
        // The user server is written back although the switch was off.
        '$_tool -setwebproxy Wi-Fi 10.0.0.5 8080',
        '$_tool -setwebproxystate Wi-Fi off',
      ],
    );
  });

  test('an empty restored bypass list uses the single Empty argument', () async {
    final os = _FakeOs(_network());
    final proxy = backend(os);
    final snapshot = await proxy.read();
    await proxy.apply(port: 10808, before: snapshot);
    os.commands.clear();

    await proxy.restore(snapshot);

    expect(
      os.commands.where((line) => line.contains('-setproxybypassdomains')),
      [
        '$_tool -setproxybypassdomains Wi-Fi Empty',
        '$_tool -setproxybypassdomains USB 10/100 LAN Empty',
      ],
    );
  });

  test('apply and restore never touch the automatic proxy (PAC)', () async {
    final os = _FakeOs(_network(domains: ['.corp']));
    final proxy = backend(os);
    final snapshot = await proxy.read();
    await proxy.apply(port: 10808, before: snapshot);
    await proxy.restore(snapshot);

    expect(
      os.commands.where((line) => line.toLowerCase().contains('autoproxy')),
      isEmpty,
    );
  });

  test('disable only turns off the states pointing at our port', () async {
    final os = _FakeOs(
      _network(
        webEnabled: true,
        webServer: '127.0.0.1',
        webPort: '10808',
      ),
    );
    os.commands.clear();

    await backend(os).disable(port: 10808);

    expect(
      os.commands.where((line) => line.contains('state')),
      [
        '$_tool -setwebproxystate Wi-Fi off',
        '$_tool -setwebproxystate USB 10/100 LAN off',
      ],
    );
  });

  test('a failing read aborts with a concrete reason', () async {
    await expectLater(
      backend(_FakeOs({})).read(),
      throwsA(
        isA<SystemProxyFailure>().having(
          (error) => error.message,
          'message',
          contains('-listallnetworkservices'),
        ),
      ),
    );
  });
}
