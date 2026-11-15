/// System proxy values a backend reads before it applies or restores.
///
/// [values] holds the raw platform text per backend-owned key. Restore must
/// write those strings back unchanged so a byte-for-byte rollback is possible
/// even for values the App never understood.
final class SystemProxyRead {
  const SystemProxyRead({
    required this.enabled,
    required this.host,
    required this.port,
    required this.bypass,
    required this.values,
  });

  /// True when the OS proxy is currently switched on in any form.
  final bool enabled;

  /// Main proxy host used for stale-proxy detection.
  final String? host;

  /// Main proxy port used for stale-proxy detection.
  final int? port;

  /// Bypass tokens exactly as the user currently has them.
  final List<String> bypass;

  /// Raw per-key values; a null value means the key did not exist.
  final Map<String, String?> values;

  bool pointsAtLocalProxy(int localPort) =>
      enabled && host == '127.0.0.1' && port == localPort;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'host': host,
    'port': port,
    'bypass': bypass,
    'values': values,
  };

  factory SystemProxyRead.fromJson(Map<String, dynamic> json) =>
      SystemProxyRead(
        enabled: json['enabled'] as bool,
        host: json['host'] as String?,
        port: json['port'] as int?,
        bypass: (json['bypass'] as List).cast<String>(),
        values: (json['values'] as Map).map<String, String?>(
          (key, value) => MapEntry(key as String, value as String?),
        ),
      );
}

/// A platform change failed. Messages carry the concrete command or value.
final class SystemProxyFailure implements Exception {
  const SystemProxyFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Appends missing [required] tokens to the user's [current] list. Existing
/// entries keep their order and text; nothing is duplicated or dropped.
List<String> mergeProxyBypass(List<String> current, List<String> required) {
  final merged = <String>[];
  for (final token in [...current, ...required]) {
    if (!merged.contains(token)) merged.add(token);
  }
  return merged;
}
