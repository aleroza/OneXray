import 'dart:io';

import 'package:onexray/core/system_proxy/system_proxy_models.dart';

/// Result of one external command used by a system proxy backend.
final class SystemProxyCommandResult {
  const SystemProxyCommandResult({
    required this.exitCode,
    this.output = '',
    this.errorText = '',
  });

  final int exitCode;

  /// Trimmed standard output.
  final String output;

  /// Trimmed standard error or a spawn failure message.
  final String errorText;

  bool get success => exitCode == 0;
}

/// Runs [executable] with [arguments]; injectable so tests never touch the OS.
typedef SystemProxyCommandRunner =
    Future<SystemProxyCommandResult> Function(
      String executable,
      List<String> arguments,
    );

Future<SystemProxyCommandResult> runSystemProxyProcess(
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await Process.run(executable, arguments);
    return SystemProxyCommandResult(
      exitCode: result.exitCode,
      output: result.stdout.toString().trim(),
      errorText: result.stderr.toString().trim(),
    );
  } on ProcessException catch (error) {
    return SystemProxyCommandResult(
      exitCode: -1,
      errorText: '${error.executable}: ${error.message}',
    );
  }
}

/// One planned invocation. Optional commands keep going after a failure.
final class SystemProxyCommand {
  const SystemProxyCommand(
    this.executable,
    this.arguments, {
    this.optional = false,
  });

  final String executable;
  final List<String> arguments;
  final bool optional;

  String describe() => '$executable ${arguments.join(' ')}';
}

/// The single execution point for every command plan: calls stay strictly
/// sequential, and the first required failure aborts the plan.
Future<void> runSystemProxyCommands(
  SystemProxyCommandRunner run,
  List<SystemProxyCommand> commands,
) async {
  for (final command in commands) {
    final result = await run(command.executable, command.arguments);
    if (result.success || command.optional) continue;
    final reason = result.errorText.isEmpty
        ? command.describe()
        : '${command.describe()}: ${result.errorText}';
    throw SystemProxyFailure('System proxy command failed: $reason');
  }
}
