import 'dart:io';

import 'package:onexray/core/system_proxy/system_proxy_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:onexray/core/tools/logger.dart';
import 'package:onexray/service/shared/command_serial_executor.dart';
import 'package:onexray/service/shared/system_proxy/snapshot_store.dart';

/// Applies and rolls back the stored system proxy intent, one operation at a
/// time on a serial queue.
///
/// The persisted snapshot doubles as the "we applied it" marker: an apply
/// without a snapshot first captures the user values, a remove without a
/// snapshot leaves foreign proxy settings alone, and a failed apply keeps the
/// snapshot so a later remove still retries the rollback.
///
/// No method ever throws: a returned string is the concrete failure reason
/// for the UI, and `null` means success or nothing to do.
final class SystemProxyService {
  SystemProxyService({
    SystemProxyBackend? Function()? backendFactory,
    SystemProxySnapshotStore? store,
    Future<bool> Function(int port)? portInUse,
  }) : _backendFactory = backendFactory ?? defaultSystemProxyBackend,
       _store = store ?? SystemProxySnapshotStore(),
       _portInUse = portInUse ?? _loopbackPortInUse;

  static final instance = SystemProxyService();

  final SystemProxyBackend? Function() _backendFactory;
  final SystemProxySnapshotStore _store;
  final Future<bool> Function(int port) _portInUse;
  final CommandSerialExecutor _queue = CommandSerialExecutor();
  bool _backendResolved = false;
  SystemProxyBackend? _backend;

  /// Port of the most recent apply that this process has not rolled back
  /// yet. It drives the guaranteed disable fallback when the snapshot file
  /// itself cannot be read.
  int? _pendingPort;

  /// Points the OS proxy at [port] and returns null, or returns the failure
  /// reason. The snapshot of the user values is captured exactly once, so a
  /// repeated apply never records our own values as the original state.
  Future<String?> apply(int port) => _queue.run(() => _apply(port));

  /// Restores a previously applied proxy. Null when nothing of ours is
  /// applied; a failed restore keeps the snapshot for the next attempt.
  Future<String?> remove() => _queue.run(() => _remove());

  /// At startup: when the system proxy points at our managed port but no one
  /// listens there, roll it back. A proxy aimed at any other address belongs
  /// to the user and stays untouched.
  Future<void> clearStaleProxy({
    required int port,
    required bool intentEnabled,
  }) => _queue.run(
    () => _clearStale(port: port, intentEnabled: intentEnabled),
  );

  Future<String?> _apply(int port) async {
    try {
      final backend = _resolveBackend();
      if (backend == null) {
        return 'This platform has no system proxy support';
      }
      var snapshot = await _store.read();
      if (snapshot != null && snapshot.backendId != backend.id) {
        return 'The saved system proxy snapshot belongs to the '
            '${snapshot.backendId} backend';
      }
      if (snapshot == null) {
        // Capture and persist before touching anything. The port is stored
        // with the snapshot so even a process restart knows which port our
        // fallback must switch off.
        snapshot = SystemProxySnapshot(
          backend.id,
          await backend.read(),
          port: port,
        );
        await _store.write(snapshot);
      }
      await backend.apply(port: port, before: snapshot.read);
      _pendingPort = port;
      return null;
    } on SystemProxyFailure catch (error) {
      ygLogger('Apply system proxy failed: $error');
      return error.message;
    } catch (error) {
      ygLogger('Apply system proxy failed: $error');
      return '$error';
    }
  }

  Future<String?> _remove() async {
    try {
      if (_pendingPort == null && !_store.hasAttemptedResolve) {
        // Nothing was applied in this process and the platform directory has
        // never been asked about: a quit must not start a platform round
        // trip it can neither bound nor need. A snapshot left by an earlier
        // process is finished by the startup cleanup.
        return null;
      }
      SystemProxySnapshot? snapshot;
      String? failure;
      try {
        snapshot = await _store.read();
      } on Object catch (error) {
        failure = '$error';
      }
      if (failure == null && snapshot == null) {
        _pendingPort = null;
        return null;
      }
      final backend = _resolveBackend();
      final port = snapshot?.port ?? _pendingPort;
      if (backend == null) {
        return failure ?? 'This platform has no system proxy support';
      }
      if (snapshot != null && failure == null) {
        if (snapshot.backendId == backend.id) {
          try {
            await backend.restore(snapshot.read);
            await _store.clear();
            _pendingPort = null;
            return null;
          } on Object catch (error) {
            failure = '$error';
          }
        } else {
          failure = 'The system proxy snapshot could not be restored by this '
              'backend (captured by ${snapshot.backendId})';
        }
      }
      // No byte-for-byte restore was possible (unreadable snapshot, foreign
      // backend or failing restore). Switch our port off so the operating
      // system cannot keep pointing at a dead listener, and keep the
      // snapshot so a later attempt can still restore byte for byte.
      if (port != null) {
        try {
          await backend.disable(port: port);
        } on Object catch (error) {
          ygLogger('System proxy disable fallback failed: $error');
        }
      }
      return failure ?? 'The system proxy state could not be restored';
    } on SystemProxyFailure catch (error) {
      ygLogger('Restore system proxy failed: $error');
      return error.message;
    } catch (error) {
      ygLogger('Restore system proxy failed: $error');
      return '$error';
    }
  }

  Future<void> _clearStale({required int port, required bool intentEnabled}) async {
    try {
      final backend = _resolveBackend();
      if (backend == null) return;
      final snapshot = await _store.read();
      if (!intentEnabled && snapshot == null) return;
      final current = await backend.read();
      if (!current.pointsAtLocalProxy(port)) return;
      if (await _portInUse(port)) return;
      if (snapshot != null && snapshot.backendId == backend.id) {
        await backend.restore(snapshot.read);
        await _store.clear();
      } else {
        // Either no snapshot at all or one captured by a different backend:
        // the proxy still provably points at our managed port, so switch it
        // off and drop the stale snapshot instead of leaving both.
        await backend.disable(port: port);
        if (snapshot != null) {
          await _store.clear();
        }
      }
      _pendingPort = null;
    } catch (error) {
      ygLogger('Clear stale system proxy failed: $error');
    }
  }

  SystemProxyBackend? _resolveBackend() {
    if (_backendResolved) return _backend;
    _backendResolved = true;
    try {
      _backend = _backendFactory();
    } catch (error) {
      ygLogger('System proxy backend unavailable: $error');
    }
    return _backend;
  }

  static Future<bool> _loopbackPortInUse(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
