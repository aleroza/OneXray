import 'dart:io';

import 'package:onexray/core/system_proxy/command_runner.dart';
import 'package:onexray/core/system_proxy/gvariant.dart';
import 'package:onexray/core/system_proxy/system_proxy_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:path/path.dart' as p;

/// One usable Linux plan: either the GSettings schemas (GNOME/MATE and
/// compatible) or the KDE kioslaverc file written by kwriteconfig.
final class _LinuxTarget {
  const _LinuxTarget.gnome(this.schema) : writeTool = null;

  const _LinuxTarget.kde(this.writeTool) : schema = null;

  final String? schema;
  final String? writeTool;

  bool get isGnome => schema != null;
}

/// Linux system proxy backend.
///
/// GNOME and MATE share the `org.<name>.system.proxy` schema layout; KDE
/// stores its values in `kioslaverc` under the `[Proxy Settings]` group.
/// `XDG_CURRENT_DESKTOP` selects the preferred plan, and tool presence
/// (checked with `which`) decides availability.
final class LinuxSystemProxyBackend implements SystemProxyBackend {
  LinuxSystemProxyBackend({
    Map<String, String>? environment,
    SystemProxyCommandRunner? run,
  }) : _environment = environment ?? Platform.environment,
       _run = run ?? runSystemProxyProcess;

  final Map<String, String> _environment;
  final SystemProxyCommandRunner _run;

  bool _resolved = false;
  _LinuxTarget? _target;

  static const _gnomeSchema = 'org.gnome.system.proxy';
  static const _mateSchema = 'org.mate.system.proxy';
  static const _kdeGnomeFallback = _LinuxTarget.gnome(_gnomeSchema);
  static const _kdeTarget = _LinuxTarget.kde('kwriteconfig6');

  /// Snapshot keys in restore order. `mode` is written last so the proxy
  /// never switches to manual while only half of the values are in place.
  static const _gnomeKeys = <String, (String, String)>{
    'ignore-hosts': ('', 'ignore-hosts'),
    'http.host': ('.http', 'host'),
    'http.port': ('.http', 'port'),
    'https.host': ('.https', 'host'),
    'https.port': ('.https', 'port'),
    'socks.host': ('.socks', 'host'),
    'socks.port': ('.socks', 'port'),
    'mode': ('', 'mode'),
  };

  static const _kdeKeys = [
    'httpProxy',
    'httpsProxy',
    'socksProxy',
    'NoProxyFor',
    'ProxyType',
  ];

  @override
  String get id => 'linux';

  /// GIO understands exact addresses or CIDR in `ignore-hosts`, not wildcards.
  static const _gnomeBypassTokens = ['localhost', '127.0.0.1', '::1'];

  /// KIO accepts the `127.*` wildcard.
  static const _kdeBypassTokens = ['localhost', '127.*', '::1'];

  @override
  Future<bool> isAvailable() async => await _resolveTarget() != null;

  @override
  Future<SystemProxyRead> read() async {
    final target = await _requireTarget();
    return target.isGnome
        ? await _readGnome(target)
        : await _readKde(target);
  }

  @override
  Future<void> apply({required int port, required SystemProxyRead before}) async {
    final target = await _requireTarget();
    if (target.isGnome) {
      final schema = target.schema!;
      final merged = formatGVariantStrings(
        mergeProxyBypass(before.bypass, _gnomeBypassTokens),
      );
      await runSystemProxyCommands(_run, [
        for (final child in ['http', 'https', 'socks']) ...[
          SystemProxyCommand(
            'gsettings',
            ['set', '$schema.$child', 'host', '127.0.0.1'],
          ),
          SystemProxyCommand(
            'gsettings',
            ['set', '$schema.$child', 'port', '$port'],
          ),
        ],
        SystemProxyCommand(
          'gsettings',
          ['set', schema, 'ignore-hosts', merged],
        ),
        SystemProxyCommand('gsettings', ['set', schema, 'mode', 'manual']),
      ]);
      return;
    }
    final tool = await _kdeWriteTool(target);
    await runSystemProxyCommands(_run, [
      ..._kdeSetCommands(
        tool,
        'httpProxy',
        'http://127.0.0.1:$port',
      ),
      ..._kdeSetCommands(
        tool,
        'httpsProxy',
        'http://127.0.0.1:$port',
      ),
      ..._kdeSetCommands(tool, 'socksProxy', 'socks://127.0.0.1:$port'),
      ..._kdeSetCommands(
        tool,
        'NoProxyFor',
        mergeProxyBypass(before.bypass, _kdeBypassTokens).join(','),
      ),
      ..._kdeSetCommands(tool, 'ProxyType', '1'),
      _kdeReparseCommand(),
    ]);
  }

  @override
  Future<void> restore(SystemProxyRead snapshot) async {
    final target = await _requireTarget();
    if (target.isGnome) {
      final schema = target.schema!;
      await runSystemProxyCommands(_run, [
        for (final entry in _gnomeKeys.entries)
          if (snapshot.values.containsKey(entry.key) &&
              snapshot.values[entry.key] != null)
            SystemProxyCommand(
              'gsettings',
              [
                'set',
                '$schema${entry.value.$1}',
                entry.value.$2,
                snapshot.values[entry.key]!,
              ],
            ),
      ]);
      return;
    }
    final tool = await _kdeWriteTool(target);
    final commands = <SystemProxyCommand>[];
    for (final key in _kdeKeys) {
      // A key the user never had is written as empty: kwriteconfig cannot
      // remove entries, and ProxyType falls back to 0 (proxy off).
      final raw = snapshot.values[key] ?? (key == 'ProxyType' ? '0' : '');
      commands.addAll(_kdeSetCommands(tool, key, raw));
    }
    commands.add(_kdeReparseCommand());
    await runSystemProxyCommands(_run, commands);
  }

  SystemProxyCommand _kdeReparseCommand() => SystemProxyCommand(
    'dbus-send',
    [
      '--session',
      '--type=signal',
      '/KIO/Scheduler',
      'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
      'string:',
    ],
    optional: true,
  );

  @override
  Future<void> disable({required int port}) async {
    final target = await _requireTarget();
    if (target.isGnome) {
      await runSystemProxyCommands(_run, [
        SystemProxyCommand('gsettings', ['set', target.schema!, 'mode', 'none']),
      ]);
      return;
    }
    final tool = await _kdeWriteTool(target);
    await runSystemProxyCommands(_run, [
      ..._kdeSetCommands(tool, 'ProxyType', '0'),
      _kdeReparseCommand(),
    ]);
  }

  Future<_LinuxTarget?> _resolveTarget() async {
    if (_resolved) return _target;
    _resolved = true;
    for (final candidate in _candidates()) {
      if (await _isTargetAvailable(candidate)) {
        _target = candidate;
        break;
      }
    }
    return _target;
  }

  Future<_LinuxTarget> _requireTarget() async =>
      await _resolveTarget() ??
      (throw const SystemProxyFailure(
        'Neither gsettings nor kwriteconfig is available',
      ));

  List<_LinuxTarget> _candidates() {
    final desktops = (_environment['XDG_CURRENT_DESKTOP'] ?? '')
        .split(':')
        .map((value) => value.trim().toUpperCase())
        .where((value) => value.isNotEmpty)
        .toSet();
    if (desktops.intersection({'KDE', 'PLASMA'}).isNotEmpty) {
      return const [_kdeTarget, _kdeGnomeFallback];
    }
    if (desktops.contains('MATE')) {
      return const [_LinuxTarget.gnome(_mateSchema)];
    }
    return const [_kdeGnomeFallback, _kdeTarget];
  }

  Future<bool> _isTargetAvailable(_LinuxTarget target) async {
    if (target.isGnome) {
      if (!await _which('gsettings')) return false;
      // A gsettings binary without the schema (GNOME tools on a bare KDE)
      // must not beat the kioslaverc plan, so probe one known key.
      final probe = await _run('gsettings', ['get', target.schema!, 'mode']);
      return probe.success;
    }
    if (await _which('kwriteconfig6')) {
      _kdeTool = 'kwriteconfig6';
      return true;
    }
    if (await _which('kwriteconfig5')) {
      _kdeTool = 'kwriteconfig5';
      return true;
    }
    return false;
  }

  Future<bool> _which(String name) async =>
      (await _run('which', [name])).success;

  String? _kdeTool;

  Future<String> _kdeWriteTool(_LinuxTarget target) async {
    final cached = _kdeTool;
    if (cached != null) return cached;
    final String tool;
    if (await _which(target.writeTool!)) {
      tool = target.writeTool!;
    } else if (await _which('kwriteconfig5')) {
      tool = 'kwriteconfig5';
    } else {
      throw const SystemProxyFailure(
        'kwriteconfig6 and kwriteconfig5 are missing',
      );
    }
    _kdeTool = tool;
    return tool;
  }

  List<SystemProxyCommand> _kdeSetCommands(String tool, String key, String value) {
    final file = _kioFile();
    return [
      SystemProxyCommand(tool, [
        '--file',
        file,
        '--group',
        'Proxy Settings',
        '--key',
        key,
        value,
      ]),
    ];
  }

  String _kioFile() {
    final xdgConfigHome = _environment['XDG_CONFIG_HOME']?.trim();
    final home = _environment['HOME']?.trim();
    final configHome = xdgConfigHome?.isNotEmpty == true
        ? xdgConfigHome!
        : home?.isNotEmpty == true
        ? p.join(home!, '.config')
        : null;
    if (configHome == null) {
      throw const SystemProxyFailure('Cannot resolve the kioslaverc path');
    }
    return p.join(configHome, 'kioslaverc');
  }

  Future<SystemProxyRead> _readGnome(_LinuxTarget target) async {
    final schema = target.schema!;
    final values = <String, String?>{};
    for (final entry in _gnomeKeys.entries) {
      final result = await _run(
        'gsettings',
        ['get', '$schema${entry.value.$1}', entry.value.$2],
      );
      if (!result.success) {
        throw SystemProxyFailure(
          'gsettings get $schema${entry.value.$1} ${entry.value.$2} '
          'failed: ${result.errorText}',
        );
      }
      values[entry.key] = result.output.isEmpty ? null : result.output;
    }
    final mode = _stripGVariantString(values['mode']);
    final host = _stripGVariantString(values['http.host']);
    return SystemProxyRead(
      enabled: mode == 'manual',
      host: host.isEmpty ? null : host,
      port: int.tryParse(values['http.port']?.trim() ?? ''),
      bypass: values['ignore-hosts'] == null
          ? const []
          : parseGVariantStrings(values['ignore-hosts']!),
      values: values,
    );
  }

  Future<SystemProxyRead> _readKde(_LinuxTarget target) async {
    final file = File(_kioFile());
    final text = await file.exists() ? await file.readAsString() : '';
    final values = _parseProxySection(text);
    final endpoint = _parseKioEndpoint(values['httpProxy']);
    return SystemProxyRead(
      enabled: values['ProxyType']?.trim() == '1',
      host: endpoint?.$1,
      port: endpoint?.$2,
      bypass: (values['NoProxyFor'] ?? '')
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(),
      values: values,
    );
  }

  /// Reads `Key=Value` lines from the `[Proxy Settings]` group only. Keys the
  /// file does not contain map to null so restore can tell them apart.
  static Map<String, String?> _parseProxySection(String text) {
    final values = <String, String?>{for (final key in _kdeKeys) key: null};
    var inGroup = false;
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        inGroup = line == '[Proxy Settings]';
        continue;
      }
      if (!inGroup || line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      final separator = line.indexOf('=');
      final key = separator < 0 ? line : line.substring(0, separator);
      if (!values.containsKey(key)) continue;
      values[key] = separator < 0 ? '' : line.substring(separator + 1);
    }
    return values;
  }

  static (String, int)? _parseKioEndpoint(String? value) {
    final match = RegExp(r'^[A-Za-z]+://([^/]+)(/.*)?$').firstMatch(
      value?.trim() ?? '',
    );
    if (match == null) return null;
    final authority = match.group(1)!;
    final separator = authority.lastIndexOf(':');
    if (separator <= 0) return null;
    final port = int.tryParse(authority.substring(separator + 1));
    if (port == null) return null;
    return (authority.substring(0, separator), port);
  }
}

/// Removes the GVariant single quotes from a scalar value.
String _stripGVariantString(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.length >= 2 && text.startsWith("'") && text.endsWith("'")) {
    return text.substring(1, text.length - 1);
  }
  return text;
}
