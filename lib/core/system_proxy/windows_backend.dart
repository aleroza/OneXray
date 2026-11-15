import 'package:onexray/core/system_proxy/system_proxy_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:onexray/core/system_proxy/windows_registry.dart';

/// Windows system proxy backend for the user's Internet Settings registry key.
///
/// `ProxyEnable`, `ProxyServer` and `ProxyOverride` are captured before the
/// first apply and written back unchanged on restore, in the registry type
/// they had; values the user never had are deleted again. The enable switch
/// is written last on apply and on restoring an enabled snapshot, so an
/// interrupted write can never leave the proxy on without its server.
/// Every change — apply, restore and disable — ends with a WinINet
/// notification so live processes re-read the key.
final class WindowsSystemProxyBackend implements SystemProxyBackend {
  WindowsSystemProxyBackend({required this.open});

  /// Opens the registry view; tests inject an in-memory stand-in.
  final WindowsRegistryAccess Function() open;

  /// WinINet documents `<local>` and host patterns, while numeric wildcards
  /// may not match everywhere, so both exact and wildcard forms are merged;
  /// mergeProxyBypass never duplicates and never replaces user entries.
  static const _bypassTokens = [
    'localhost',
    '127.0.0.1',
    '127.*',
    '[::1]',
  ];

  static const _enableName = 'ProxyEnable';
  static const _serverName = 'ProxyServer';
  static const _overrideName = 'ProxyOverride';

  /// Snapshot companion key remembering the registry type of `ProxyEnable`
  /// (`dword` or `sz`) so restore writes back exactly what was read.
  static const _enableTypeKey = 'ProxyEnable#type';

  @override
  String get id => 'windows';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SystemProxyRead> read() async => _withRegistry((registry) {
    final enable = registry.readValue(_enableName);
    final server = registry.readValue(_serverName);
    final overrideValue = registry.readValue(_overrideName);
    final endpoint = _splitEndpoint(server?.text);
    return SystemProxyRead(
      enabled: enable != null && _enableIsOn(enable),
      host: endpoint?.$1,
      port: endpoint?.$2,
      bypass: (overrideValue?.text ?? '')
          .split(';')
          .where((value) => value.isNotEmpty)
          .toList(),
      values: {
        _enableName: enable?.number?.toString() ?? enable?.text,
        if (enable != null)
          _enableTypeKey: enable.number != null ? 'dword' : 'sz',
        _serverName: server?.text,
        _overrideName: overrideValue?.text,
      },
    );
  });

  @override
  Future<void> apply({required int port, required SystemProxyRead before}) async {
    _withRegistry((registry) {
      // The switch goes last: a half-written apply must never enable a proxy
      // whose server value is still missing.
      registry.setStringValue(_serverName, '127.0.0.1:$port');
      registry.setStringValue(
        _overrideName,
        mergeProxyBypass(before.bypass, _bypassTokens).join(';'),
      );
      registry.setDwordValue(_enableName, 1);
      registry.notifySettingsChanged();
    });
  }

  @override
  Future<void> restore(SystemProxyRead snapshot) async {
    _withRegistry((registry) {
      final raw = snapshot.values[_enableName];
      final type = snapshot.values[_enableTypeKey];
      void writeEnable() {
        if (raw == null) {
          registry.deleteValue(_enableName);
        } else if (type == 'sz') {
          registry.setStringValue(_enableName, raw);
        } else {
          registry.setDwordValue(_enableName, int.tryParse(raw) ?? 0);
        }
      }

      final wasEnabled = raw != null && _enableTextIsOn(raw, type);
      void restoreValue(String name) {
        final value = snapshot.values[name];
        if (value == null) {
          registry.deleteValue(name);
        } else {
          registry.setStringValue(name, value);
        }
      }

      if (wasEnabled) {
        // Restore the data first, flip the switch on last.
        restoreValue(_serverName);
        restoreValue(_overrideName);
        writeEnable();
      } else {
        // The snapshot had the proxy off: switch it off (or delete the
        // value) first, so an interruption can only leave a disabled proxy.
        writeEnable();
        restoreValue(_serverName);
        restoreValue(_overrideName);
      }
      registry.notifySettingsChanged();
    });
  }

  @override
  Future<void> disable({required int port}) async {
    _withRegistry((registry) {
      registry.setDwordValue(_enableName, 0);
      registry.notifySettingsChanged();
    });
  }

  /// Runs [action] against one opened registry view and always closes it.
  T _withRegistry<T>(T Function(WindowsRegistryAccess registry) action) {
    final registry = open();
    try {
      return action(registry);
    } finally {
      registry.close();
    }
  }

  static bool _enableIsOn(RegistryValue enable) =>
      (enable.number ?? 0) == 1 || enable.text == '1';

  static bool _enableTextIsOn(String raw, String? type) =>
      type == 'sz' ? raw == '1' : (int.tryParse(raw) ?? 0) != 0;

  static (String, int)? _splitEndpoint(String? server) {
    final text = server?.trim() ?? '';
    if (text.isEmpty) return null;
    final separator = text.lastIndexOf(':');
    if (separator <= 0) return null;
    final port = int.tryParse(text.substring(separator + 1));
    if (port == null) return null;
    return (text.substring(0, separator), port);
  }
}
