import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/system_proxy/command_runner.dart';
import 'package:onexray/core/system_proxy/linux_backend.dart';
import 'package:path/path.dart' as p;

import '../../support/test_directory.dart';

class _FakeOs {
  _FakeOs({Set<String>? tools}) : tools = tools ?? {'kwriteconfig5'};

  final Set<String> tools;
  final commands = <String>[];
  bool dbusFails = true;
  bool gsettingsFails = false;

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
    if (executable == 'gsettings' && gsettingsFails) {
      return const SystemProxyCommandResult(
        exitCode: 1,
        errorText: 'No such schema org.gnome.system.proxy',
      );
    }
    if (executable == 'dbus-send' && dbusFails) {
      return const SystemProxyCommandResult(
        exitCode: 1,
        errorText: 'D-Bus session unavailable',
      );
    }
    return const SystemProxyCommandResult(exitCode: 0);
  }
}

void main() {
  late Directory configHome;
  late File kioFile;

  setUp(() async {
    configHome = await createTestDirectory('onexray-kioslaverc-');
    kioFile = File(p.join(configHome.path, 'kioslaverc'));
  });

  tearDown(() async {
    if (await configHome.exists()) {
      await configHome.delete(recursive: true);
    }
  });

  LinuxSystemProxyBackend backend(_FakeOs os) => LinuxSystemProxyBackend(
    environment: {
      'XDG_CURRENT_DESKTOP': 'KDE',
      'XDG_CONFIG_HOME': configHome.path,
    },
    run: os.call,
  );

  test('reads only the Proxy Settings group', () async {
    await kioFile.writeAsString(
      '[General]\n'
      'ProxyType=9\n'
      '\n'
      '[Proxy Settings]\n'
      'ProxyType=0\n'
      'httpProxy=http://proxy.internal:3128\n'
      'NoProxyFor=localhost, .corp\n',
    );
    final os = _FakeOs();

    final state = await backend(os).read();

    expect(state.enabled, isFalse);
    expect(state.host, 'proxy.internal');
    expect(state.port, 3128);
    expect(state.bypass, ['localhost', '.corp']);
    expect(state.values['httpsProxy'], isNull);
    expect(state.values['ProxyType'], '0');
  });

  test('apply keeps the user list, orders ProxyType last and tolerates no D-Bus',
      () async {
    await kioFile.writeAsString(
      '[Proxy Settings]\n'
      'ProxyType=0\n'
      'NoProxyFor=localhost, .corp\n',
    );
    final os = _FakeOs();
    final proxy = backend(os);
    final before = await proxy.read();
    os.commands.clear();

    await proxy.apply(port: 10808, before: before);

    final file = kioFile.path;
    expect(os.commands, [
      'kwriteconfig5 --file $file --group Proxy Settings --key httpProxy '
          'http://127.0.0.1:10808',
      'kwriteconfig5 --file $file --group Proxy Settings --key httpsProxy '
          'http://127.0.0.1:10808',
      'kwriteconfig5 --file $file --group Proxy Settings --key socksProxy '
          'socks://127.0.0.1:10808',
      'kwriteconfig5 --file $file --group Proxy Settings --key NoProxyFor '
          'localhost,.corp,127.*,::1',
      'kwriteconfig5 --file $file --group Proxy Settings --key ProxyType 1',
      'dbus-send --session --type=signal /KIO/Scheduler '
          'org.kde.KIO.Scheduler.reparseSlaveConfiguration string:',
    ]);
  });

  test('restore writes captured values byte for byte and clears absent keys',
      () async {
    await kioFile.writeAsString(
      '[Proxy Settings]\n'
      'ProxyType=0\n'
      'httpProxy=http://proxy.internal:3128\n'
      'NoProxyFor=localhost, .corp\n',
    );
    final os = _FakeOs();
    final proxy = backend(os);
    final snapshot = await proxy.read();
    await proxy.apply(port: 10808, before: snapshot);
    os.commands.clear();

    await proxy.restore(snapshot);

    final file = kioFile.path;
    expect(os.commands, [
      'kwriteconfig5 --file $file --group Proxy Settings --key httpProxy '
          'http://proxy.internal:3128',
      'kwriteconfig5 --file $file --group Proxy Settings --key httpsProxy ',
      'kwriteconfig5 --file $file --group Proxy Settings --key socksProxy ',
      'kwriteconfig5 --file $file --group Proxy Settings --key NoProxyFor '
          'localhost, .corp',
      'kwriteconfig5 --file $file --group Proxy Settings --key ProxyType 0',
      'dbus-send --session --type=signal /KIO/Scheduler '
          'org.kde.KIO.Scheduler.reparseSlaveConfiguration string:',
    ]);
  });

  test('a previously absent ProxyType is restored as off', () async {
    final os = _FakeOs();
    final proxy = backend(os);
    final snapshot = await proxy.read();
    expect(snapshot.values['ProxyType'], isNull);
    await proxy.apply(port: 10808, before: snapshot);
    os.commands.clear();

    await proxy.restore(snapshot);

    expect(
      os.commands.where((line) => line.contains('--key ProxyType')),
      ['kwriteconfig5 --file ${kioFile.path} --group Proxy Settings '
          '--key ProxyType 0'],
    );
  });

  test('kwriteconfig6 wins when it exists', () async {
    final os = _FakeOs(tools: {'kwriteconfig6', 'kwriteconfig5'});
    final proxy = backend(os);

    await proxy.apply(port: 10808, before: await proxy.read());

    // The tool probe runs first; the first write must use kwriteconfig6.
    expect(
      os.commands.firstWhere((line) => line.contains('--file')),
      startsWith('kwriteconfig6 --file'),
    );
  });

  test('an enabled manual plan on our port is detected as ours', () async {
    await kioFile.writeAsString(
      '[Proxy Settings]\n'
      'ProxyType=1\n'
      'httpProxy=http://127.0.0.1:10808\n',
    );

    final state = await backend(_FakeOs()).read();

    expect(state.pointsAtLocalProxy(10808), isTrue);
    expect(state.pointsAtLocalProxy(10809), isFalse);
  });

  test('a gsettings binary without the schema falls back to kioslaverc',
      () async {
    await kioFile.writeAsString('[Proxy Settings]\nProxyType=0\n');
    // GNOME-style desktop, gsettings installed but the schema missing —
    // the availability probe must notice and pick the KDE plan instead of
    // failing every later write with "No such schema".
    final os = _FakeOs(tools: {'gsettings', 'kwriteconfig5'})
      ..gsettingsFails = true;
    final proxy = LinuxSystemProxyBackend(
      environment: {
        'XDG_CURRENT_DESKTOP': 'GNOME',
        'XDG_CONFIG_HOME': configHome.path,
      },
      run: os.call,
    );

    expect(await proxy.isAvailable(), isTrue);
    final state = await proxy.read();

    expect(state.enabled, isFalse);
    // The failed probe is the only gsettings call: the KDE plan took over.
    expect(os.commands.where((line) => line.startsWith('gsettings get')), [
      'gsettings get org.gnome.system.proxy mode',
    ]);
    expect(os.commands, contains('which kwriteconfig5'));
  });
}
