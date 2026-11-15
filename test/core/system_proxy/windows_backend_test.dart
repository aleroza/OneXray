import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/system_proxy/windows_backend.dart';
import 'package:onexray/core/system_proxy/windows_registry.dart';

/// In-memory stand-in for the Internet Settings key; records the operation
/// order and value type so the write plan is observable without Windows.
class _FakeRegistry implements WindowsRegistryAccess {
  final values = <String, Object>{};
  final log = <String>[];
  int notifications = 0;

  @override
  RegistryValue? readValue(String name) {
    final value = values[name];
    if (value == null) return null;
    if (value is int) return (text: null, number: value);
    return (text: value as String, number: null);
  }

  @override
  void setStringValue(String name, String value) {
    values[name] = value;
    log.add('sz $name=$value');
  }

  @override
  void setDwordValue(String name, int value) {
    values[name] = value;
    log.add('dword $name=$value');
  }

  @override
  void deleteValue(String name) {
    values.remove(name);
    log.add('delete $name');
  }

  @override
  void notifySettingsChanged() {
    notifications++;
    log.add('notify');
  }

  @override
  void close() {}
}

void main() {
  late _FakeRegistry registry;
  late WindowsSystemProxyBackend backend;

  setUp(() {
    registry = _FakeRegistry();
    backend = WindowsSystemProxyBackend(open: () => registry);
  });

  test('read decodes the DWORD, the server and the override list', () async {
    registry.values.addAll({
      'ProxyEnable': 1,
      'ProxyServer': '127.0.0.1:10808',
      'ProxyOverride': 'corp;localhost;<local>',
    });

    final state = await backend.read();

    expect(state.enabled, isTrue);
    expect(state.host, '127.0.0.1');
    expect(state.port, 10808);
    expect(state.pointsAtLocalProxy(10808), isTrue);
    expect(state.pointsAtLocalProxy(10809), isFalse);
    expect(state.bypass, ['corp', 'localhost', '<local>']);
    expect(state.values['ProxyEnable'], '1');
    expect(state.values['ProxyEnable#type'], 'dword');
    expect(state.values['ProxyServer'], '127.0.0.1:10808');
    expect(state.values['ProxyOverride'], 'corp;localhost;<local>');
  });

  test('a ProxyEnable stored as text still reads as enabled', () async {
    registry.values.addAll({'ProxyEnable': '1', 'ProxyServer': 'a:1'});

    final state = await backend.read();

    expect(state.enabled, isTrue);
    expect(state.values['ProxyEnable#type'], 'sz');
  });

  test('absent values read as null and keep the proxy off', () async {
    final state = await backend.read();

    expect(state.enabled, isFalse);
    expect(state.host, isNull);
    expect(state.bypass, isEmpty);
    expect(state.values['ProxyEnable'], isNull);
    expect(state.values['ProxyEnable#type'], isNull);
    expect(state.values['ProxyOverride'], isNull);
  });

  test('apply writes data first and the enable switch last', () async {
    registry.values['ProxyOverride'] = 'corp';
    final before = await backend.read();
    registry.log.clear();

    await backend.apply(port: 10808, before: before);

    expect(registry.log, [
      'sz ProxyServer=127.0.0.1:10808',
      'sz ProxyOverride=corp;localhost;127.0.0.1;127.*;[::1]',
      'dword ProxyEnable=1',
      'notify',
    ]);
    expect(registry.notifications, 1);
  });

  test('apply keeps user overrides and adds each missing token once',
      () async {
    registry.values['ProxyOverride'] = 'localhost;corp.internal';
    final before = await backend.read();
    registry.log.clear();

    await backend.apply(port: 10808, before: before);

    expect(
      registry.values['ProxyOverride'],
      'localhost;corp.internal;127.0.0.1;127.*;[::1]',
    );
  });

  test('restoring an off snapshot switches off before the strings', () async {
    registry.values.addAll({
      'ProxyEnable': 0,
      'ProxyServer': 'proxy.corp:3128',
      'ProxyOverride': 'a;b',
    });
    final snapshot = await backend.read();
    await backend.apply(port: 10808, before: snapshot);
    registry.log.clear();

    await backend.restore(snapshot);

    expect(registry.log, [
      'dword ProxyEnable=0',
      'sz ProxyServer=proxy.corp:3128',
      'sz ProxyOverride=a;b',
      'notify',
    ]);
    expect(registry.values['ProxyEnable'], 0);
    expect(registry.values['ProxyServer'], 'proxy.corp:3128');
    expect(registry.notifications, 2);
  });

  test('restoring an enabled snapshot writes strings first, switch last',
      () async {
    registry.values.addAll({
      'ProxyEnable': 1,
      'ProxyServer': 'proxy.corp:3128',
      'ProxyOverride': 'a;b',
    });
    final snapshot = await backend.read();
    await backend.apply(port: 10808, before: snapshot);
    registry.log.clear();

    await backend.restore(snapshot);

    expect(registry.log, [
      'sz ProxyServer=proxy.corp:3128',
      'sz ProxyOverride=a;b',
      'dword ProxyEnable=1',
      'notify',
    ]);
  });

  test('a text ProxyEnable is restored as text, not as a DWORD', () async {
    registry.values['ProxyEnable'] = '1';
    final snapshot = await backend.read();
    await backend.apply(port: 10808, before: snapshot);
    registry.log.clear();

    await backend.restore(snapshot);

    expect(registry.log, contains('sz ProxyEnable=1'));
    expect(registry.values['ProxyEnable'], '1');
  });

  test('restore deletes values that did not exist before', () async {
    final snapshot = await backend.read();
    await backend.apply(port: 10808, before: snapshot);
    registry.log.clear();

    await backend.restore(snapshot);

    expect(registry.log, [
      'delete ProxyEnable',
      'delete ProxyServer',
      'delete ProxyOverride',
      'notify',
    ]);
    expect(registry.values, isEmpty);
  });

  test('disable switches ProxyEnable off and notifies', () async {
    registry.values.addAll({'ProxyEnable': 1, 'ProxyServer': '127.0.0.1:10808'});
    registry.log.clear();

    await backend.disable(port: 10808);

    expect(registry.log, ['dword ProxyEnable=0', 'notify']);
  });
}
