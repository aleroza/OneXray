import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Values captured before the first apply, together with the backend that
/// captured them and the managed port. A restore is only allowed on the same
/// backend; the port drives the guaranteed disable fallback when a
/// byte-for-byte restore is impossible.
final class SystemProxySnapshot {
  const SystemProxySnapshot(this.backendId, this.read, {this.port});

  final String backendId;
  final SystemProxyRead read;

  /// The local port the applied proxy pointed at.
  final int? port;

  Map<String, dynamic> toJson() => {
    'backendId': backendId,
    'read': read.toJson(),
    if (port != null) 'port': port,
  };

  factory SystemProxySnapshot.fromJson(Map<String, dynamic> json) =>
      SystemProxySnapshot(
        json['backendId']! as String,
        SystemProxyRead.fromJson(json['read']! as Map<String, dynamic>),
        port: json['port'] as int?,
      );
}

/// The snapshot persists as one JSON file, so the pending rollback survives
/// an app crash or a killed process.
///
/// The directory query goes to a platform channel that may never answer (a
/// test binding without a handler, a wedged platform), so the resolution is
/// performed once, cached with its outcome and bounded by [resolveTimeout].
/// Callers then either get the path or a decisive [SystemProxyFailure] —
/// never an eternal await.
final class SystemProxySnapshotStore {
  SystemProxySnapshotStore({Future<String> Function()? directory})
    : _directory = directory ?? _supportDirectory;

  final Future<String> Function() _directory;

  static const _fileName = 'system-proxy-snapshot.json';

  /// How long the platform may take to answer the directory query before it
  /// is declared unavailable; keeps quit paths finite.
  static const resolveTimeout = Duration(seconds: 2);

  Future<String>? _resolution;

  /// True once a directory resolution has been started in this process.
  /// Callers use it to skip platform IO a fresh process cannot finish anyway.
  bool get hasAttemptedResolve => _resolution != null;

  static Future<String> _supportDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  /// The single resolution of this process: created at most once, cached
  /// including its failure, and turned into a [SystemProxyFailure] on
  /// timeout so a stuck channel cannot block anything.
  Future<String> _resolveDirectory() {
    final cached = _resolution;
    if (cached != null) return cached;
    final resolution = () async {
      try {
        return await _directory().timeout(resolveTimeout);
      } on TimeoutException {
        throw const SystemProxyFailure(
          'Resolving the application support directory timed out',
        );
      } catch (error) {
        throw SystemProxyFailure(
          'Application support directory unavailable: $error',
        );
      }
    }();
    _resolution = resolution;
    return resolution;
  }

  Future<String> _path() async =>
      p.join(await _resolveDirectory(), _fileName);

  /// Null only when no snapshot file exists; a damaged file is an error so
  /// the caller never overwrites the only copy of the user's values.
  Future<SystemProxySnapshot?> read() async {
    final file = File(await _path());
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid system proxy snapshot');
    }
    return SystemProxySnapshot.fromJson(json);
  }

  Future<void> write(SystemProxySnapshot snapshot) async {
    final path = await _path();
    final temporary = File('$path.tmp');
    await temporary.parent.create(recursive: true);
    await temporary.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    await temporary.rename(path);
  }

  Future<void> clear() async {
    final file = File(await _path());
    if (await file.exists()) {
      await file.delete();
    }
  }
}
