import 'dart:io';

import 'package:onexray/core/system_proxy/command_runner.dart';
import 'package:onexray/core/system_proxy/system_proxy_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:onexray/core/tools/logger.dart';

/// macOS system proxy backend based on `/usr/sbin/networksetup`.
///
/// Values are captured per network service and per proxy kind. The snapshot
/// keeps the raw `Enabled`/`Server`/`Port` text so restore can put every
/// service back exactly as it was. PAC (automatic proxy) settings are never
/// read, changed or restored by this backend.
final class MacSystemProxyBackend implements SystemProxyBackend {
  MacSystemProxyBackend({
    SystemProxyCommandRunner? run,
    this.tool = '/usr/sbin/networksetup',
  }) : _run = run ?? runSystemProxyProcess;

  final SystemProxyCommandRunner _run;

  /// The `networksetup` binary path, overridable for diagnostics.
  final String tool;

  static const _bypassTokens = ['localhost', '127.0.0.1', '::1'];

  /// set/state/get command triplets plus the snapshot key for each kind.
  static const _kinds = <String, (String, String, String)>{
    'web': ('-setwebproxy', '-setwebproxystate', '-getwebproxy'),
    'secureweb': (
      '-setsecurewebproxy',
      '-setsecurewebproxystate',
      '-getsecurewebproxy',
    ),
    'socksfirewall': (
      '-setsocksfirewallproxy',
      '-setsocksfirewallproxystate',
      '-getsocksfirewallproxy',
    ),
  };

  @override
  String get id => 'macos';

  @override
  Future<bool> isAvailable() async => await File(tool).exists();

  @override
  Future<SystemProxyRead> read() async {
    final services = await _enabledServices();
    final values = <String, String?>{'services': services.join('\n')};
    var enabled = false;
    String? host;
    int? port;
    var bypass = const <String>[];
    for (final service in services) {
      final domains = await _readBypassDomains(service);
      values['$service|bypass'] = domains.join('\n');
      for (final kind in _kinds.keys) {
        final settings = _parseSettings(
          await _runRequired([_kinds[kind]!.$3, service]),
        );
        values['$service|$kind|enabled'] = settings['Enabled'];
        values['$service|$kind|server'] = settings['Server'];
        values['$service|$kind|port'] = settings['Port'];
        if (!enabled && settings['Enabled'] == 'Yes') {
          enabled = true;
          host = settings['Server']?.isEmpty ?? true ? null : settings['Server'];
          port = int.tryParse(settings['Port']?.trim() ?? '');
          bypass = domains;
        }
      }
    }
    return SystemProxyRead(
      enabled: enabled,
      host: host,
      port: port,
      bypass: bypass,
      values: values,
    );
  }

  @override
  Future<void> apply({required int port, required SystemProxyRead before}) async {
    final services = _servicesOf(before);
    final commands = <SystemProxyCommand>[];
    for (final service in services) {
      final current = _bypassOf(before, service);
      final domains = mergeProxyBypass(current, _bypassTokens);
      for (final entry in _kinds.entries) {
        commands.add(
          SystemProxyCommand(tool, [entry.value.$1, service, '127.0.0.1', '$port']),
        );
      }
      commands.add(_setBypassCommand(service, domains));
      for (final entry in _kinds.entries) {
        commands.add(SystemProxyCommand(tool, [entry.value.$2, service, 'on']));
      }
    }
    await runSystemProxyCommands(_run, commands);
  }

  @override
  Future<void> restore(SystemProxyRead snapshot) async {
    for (final service in _servicesOf(snapshot)) {
      for (final entry in _kinds.entries) {
        final enabled = snapshot.values['$service|${entry.key}|enabled'];
        final server = snapshot.values['$service|${entry.key}|server'] ?? '';
        final port = snapshot.values['$service|${entry.key}|port'] ?? '';
        if (server.isEmpty || port.isEmpty) {
          // The user had no server here. Still write the captured values
          // back so our endpoint disappears; networksetup may reject an
          // empty server, which is tolerated, never fatal.
          final reset = await _run(
            tool,
            [entry.value.$1, service, server, port.isEmpty ? '0' : port],
          );
          if (!reset.success) {
            ygLogger(
              'Could not reset ${entry.value.$1} $service to the captured '
              'empty values: ${reset.errorText}',
            );
          }
          // An empty capture never goes back to on: with no server to point
          // at, off guarantees a leftover endpoint stays unused.
          await runSystemProxyCommands(_run, [
            SystemProxyCommand(tool, [entry.value.$2, service, 'off']),
          ]);
          continue;
        }
        // A configured but switched-off proxy must survive: the server and
        // port are restored whenever they existed, not only when enabled.
        // A kind whose capture failed gets an explicit off through the
        // branch above, so it can never stay enabled on our dead port.
        await runSystemProxyCommands(_run, [
          SystemProxyCommand(tool, [entry.value.$1, service, server, port]),
          SystemProxyCommand(
            tool,
            [entry.value.$2, service, enabled == 'Yes' ? 'on' : 'off'],
          ),
        ]);
      }
      await runSystemProxyCommands(_run, [
        _setBypassCommand(service, _bypassOf(snapshot, service)),
      ]);
    }
  }

  @override
  Future<void> disable({required int port}) async {
    final current = await read();
    final commands = <SystemProxyCommand>[];
    for (final service in _servicesOf(current)) {
      for (final entry in _kinds.entries) {
        final enabled = current.values['$service|${entry.key}|enabled'];
        final server = current.values['$service|${entry.key}|server'] ?? '';
        final actual = int.tryParse(current.values['$service|${entry.key}|port'] ?? '');
        if (enabled == 'Yes' && server == '127.0.0.1' && actual == port) {
          commands.add(
            SystemProxyCommand(tool, [entry.value.$2, service, 'off']),
          );
        }
      }
    }
    await runSystemProxyCommands(_run, commands);
  }

  SystemProxyCommand _setBypassCommand(String service, List<String> domains) =>
      SystemProxyCommand(tool, [
        '-setproxybypassdomains',
        service,
        if (domains.isEmpty) 'Empty' else ...domains,
      ]);

  List<String> _servicesOf(SystemProxyRead snapshot) {
    final services = snapshot.values['services'] ?? '';
    return services.split('\n').where((value) => value.isNotEmpty).toList();
  }

  List<String> _bypassOf(SystemProxyRead snapshot, String service) {
    final raw = snapshot.values['$service|bypass'] ?? '';
    return raw.split('\n').where((value) => value.isNotEmpty).toList();
  }

  Future<List<String>> _enabledServices() async {
    final result = await _run(tool, ['-listallnetworkservices']);
    if (!result.success) {
      throw SystemProxyFailure(
        'networksetup -listallnetworkservices failed: ${result.errorText}',
      );
    }
    return result.output.split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        // `*` marks a disabled service; the first line explains the mark.
        .where((line) => !line.startsWith('*'))
        .where((line) => !line.startsWith('An asterisk'))
        .toList();
  }

  Future<List<String>> _readBypassDomains(String service) async {
    final output = await _runRequired(['-getproxybypassdomains', service]);
    return output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        // The first line is a `Proxy Bypass Domains for "…":` header and the
        // diagnostic sentence is not a domain; neither may enter the snapshot.
        .where((line) => !line.endsWith(':'))
        .where((line) => !line.startsWith("There aren't any bypass domains"))
        .toList();
  }

  Future<String> _runRequired(List<String> arguments) async {
    final result = await _run(tool, arguments);
    if (!result.success) {
      throw SystemProxyFailure(
        'networksetup ${arguments.join(' ')} failed: ${result.errorText}',
      );
    }
    return result.output;
  }

  static Map<String, String> _parseSettings(String output) {
    final values = <String, String>{};
    for (final line in output.split('\n')) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      values[line.substring(0, separator).trim()] =
          line.substring(separator + 1).trim();
    }
    return values;
  }
}
