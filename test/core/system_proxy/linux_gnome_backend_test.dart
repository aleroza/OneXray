import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/system_proxy/command_runner.dart';
import 'package:onexray/core/system_proxy/linux_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';

/// Records every command and answers the scripted `which`/`gsettings get`
/// reads; everything else is a successful write.
class _FakeOs {
  _FakeOs({Set<String>? tools, Map<String, String>? gets})
    : tools = tools ?? {'gsettings'},
      gets = gets ?? {};

  final Set<String> tools;
  final Map<String, String> gets;
  final commands = <String>[];
  String? failOn;

  Future<SystemProxyCommandResult> call(
    String executable,
    List<String> arguments,
  ) async {
    final line = [executable, ...arguments].join(' ');
    commands.add(line);
    if (executable == 'which') {
      return tools.contains(arguments.single)
          ? SystemProxyCommandResult(
              exitCode: 0,
              output: '/usr/bin/${arguments.single}',
            )
          : const SystemProxyCommandResult(exitCode: 1);
    }
    if (executable == 'gsettings' && arguments.first == 'get') {
      final value = gets['${arguments[1]} ${arguments[2]}'];
      if (value == null) {
        return const SystemProxyCommandResult(
          exitCode: 1,
          errorText: 'no such schema',
        );
      }
      return SystemProxyCommandResult(exitCode: 0, output: value);
    }
    if (failOn != null && line.contains(failOn!)) {
      return const SystemProxyCommandResult(exitCode: 1, errorText: 'read-only');
    }
    return const SystemProxyCommandResult(exitCode: 0);
  }
}

Map<String, String> _gnomeGets({String ignoreHosts = '@as []'}) => {
  'org.gnome.system.proxy mode': "'none'",
  'org.gnome.system.proxy ignore-hosts': ignoreHosts,
  'org.gnome.system.proxy.http host': "''",
  'org.gnome.system.proxy.http port': '0',
  'org.gnome.system.proxy.https host': "''",
  'org.gnome.system.proxy.https port': '0',
  'org.gnome.system.proxy.socks host': "''",
  'org.gnome.system.proxy.socks port': '0',
};

LinuxSystemProxyBackend _backend(_FakeOs os, {String desktop = 'GNOME'}) =>
    LinuxSystemProxyBackend(
      environment: {'XDG_CURRENT_DESKTOP': desktop},
      run: os.call,
    );

void main() {
  test('read only queries values and understands the untitled empty list', () async {
    final os = _FakeOs(gets: _gnomeGets());
    final state = await _backend(os).read();

    expect(state.enabled, isFalse);
    expect(state.host, isNull);
    expect(state.port, 0);
    expect(state.bypass, isEmpty);
    expect(os.commands.where((line) => !line.startsWith('gsettings get')), [
      'which gsettings',
    ]);
    expect(
      os.commands,
      contains('gsettings get org.gnome.system.proxy ignore-hosts'),
    );
  });

  test('apply writes every protocol and switches mode manual last', () async {
    final os = _FakeOs(gets: _gnomeGets());
    final backend = _backend(os);
    final before = await backend.read();
    os.commands.clear();

    await backend.apply(port: 10808, before: before);

    expect(os.commands, [
      'gsettings set org.gnome.system.proxy.http host 127.0.0.1',
      'gsettings set org.gnome.system.proxy.http port 10808',
      'gsettings set org.gnome.system.proxy.https host 127.0.0.1',
      'gsettings set org.gnome.system.proxy.https port 10808',
      'gsettings set org.gnome.system.proxy.socks host 127.0.0.1',
      'gsettings set org.gnome.system.proxy.socks port 10808',
      "gsettings set org.gnome.system.proxy ignore-hosts ['localhost', "
          "'127.0.0.1', '::1']",
      'gsettings set org.gnome.system.proxy mode manual',
    ]);
  });

  test('apply merges missing local tokens without touching user entries',
      () async {
    final os = _FakeOs(
      gets: _gnomeGets(ignoreHosts: "['corp', 'localhost']"),
    );
    final backend = _backend(os);
    final before = await backend.read();
    os.commands.clear();

    await backend.apply(port: 10808, before: before);

    expect(
      os.commands,
      contains(
        "gsettings set org.gnome.system.proxy ignore-hosts ['corp', "
        "'localhost', '127.0.0.1', '::1']",
      ),
    );
  });

  test('restore writes the captured raw text back with mode last', () async {
    final os = _FakeOs(
      gets: {
        'org.gnome.system.proxy mode': "'manual'",
        'org.gnome.system.proxy ignore-hosts': "['corp.example']",
        'org.gnome.system.proxy.http host': "'10.0.0.1'",
        'org.gnome.system.proxy.http port': '3128',
        'org.gnome.system.proxy.https host': "'10.0.0.1'",
        'org.gnome.system.proxy.https port': '3128',
        'org.gnome.system.proxy.socks host': "'10.0.0.2'",
        'org.gnome.system.proxy.socks port': '1080',
      },
    );
    final backend = _backend(os);
    final snapshot = await backend.read();
    await backend.apply(port: 10808, before: snapshot);
    os.commands.clear();

    await backend.restore(snapshot);

    expect(os.commands, [
      'gsettings set org.gnome.system.proxy ignore-hosts [\'corp.example\']',
      'gsettings set org.gnome.system.proxy.http host \'10.0.0.1\'',
      'gsettings set org.gnome.system.proxy.http port 3128',
      'gsettings set org.gnome.system.proxy.https host \'10.0.0.1\'',
      'gsettings set org.gnome.system.proxy.https port 3128',
      'gsettings set org.gnome.system.proxy.socks host \'10.0.0.2\'',
      'gsettings set org.gnome.system.proxy.socks port 1080',
      'gsettings set org.gnome.system.proxy mode \'manual\'',
    ]);
  });

  test('restore skips keys whose capture was empty', () async {
    final os = _FakeOs(gets: _gnomeGets());
    os.gets['org.gnome.system.proxy mode'] = '';
    final backend = _backend(os);
    final snapshot = await backend.read();
    expect(snapshot.values['mode'], isNull);
    os.commands.clear();

    await backend.restore(snapshot);

    expect(
      os.commands.where((line) => line.contains('mode')),
      isEmpty,
    );
  });

  test('a failed write aborts the plan and names the command', () async {
    final os = _FakeOs(gets: _gnomeGets());
    os.failOn = 'socks host';
    final backend = _backend(os);
    final before = await backend.read();
    os.commands.clear();

    await expectLater(
      backend.apply(port: 10808, before: before),
      throwsA(
        isA<SystemProxyFailure>().having(
          (error) => error.message,
          'message',
          contains('socks host'),
        ),
      ),
    );
    expect(
      os.commands.where((line) => line.contains('mode manual')),
      isEmpty,
    );
  });

  test('a captured proxy on the managed port is detected as ours', () async {
    final os = _FakeOs(
      gets: {
        ..._gnomeGets(),
        'org.gnome.system.proxy mode': "'manual'",
        'org.gnome.system.proxy.http host': "'127.0.0.1'",
        'org.gnome.system.proxy.http port': '10808',
      },
    );
    final state = await _backend(os).read();

    expect(state.enabled, isTrue);
    expect(state.pointsAtLocalProxy(10808), isTrue);
    expect(state.pointsAtLocalProxy(10809), isFalse);
  });

  test('MATE selects the org.mate.system.proxy schema', () async {
    final os = _FakeOs();
    for (final key in ['mode', 'ignore-hosts']) {
      os.gets['org.mate.system.proxy $key'] = key == 'mode' ? "'none'" : '@as []';
    }
    for (final child in ['http', 'https', 'socks']) {
      os.gets['org.mate.system.proxy.$child host'] = "''";
      os.gets['org.mate.system.proxy.$child port'] = '0';
    }

    final state = await _backend(os, desktop: 'MATE').read();

    expect(state.enabled, isFalse);
    expect(
      os.commands,
      contains('gsettings get org.mate.system.proxy mode'),
    );
  });

  test('without any supported tool the backend is unavailable', () async {
    final os = _FakeOs(tools: const {});

    expect(await _backend(os).isAvailable(), isFalse);
    await expectLater(
      _backend(os).read(),
      throwsA(isA<SystemProxyFailure>()),
    );
  });
}
