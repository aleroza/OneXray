import 'dart:io';

import 'package:onexray/core/system_proxy/linux_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';

/// A platform-specific way to read, change and roll back the OS proxy.
///
/// Every backend is the single source of truth for its command plan: the
/// writes happen strictly in the order the backend builds them.
abstract interface class SystemProxyBackend {
  /// Stable identifier persisted with a snapshot so that a later restore stays
  /// on the backend that captured it.
  String get id;

  /// True when this platform offers the tools needed to change the proxy.
  Future<bool> isAvailable();

  /// Reads the current system values without modifying anything.
  Future<SystemProxyRead> read();

  /// Points the OS proxy at `127.0.0.1:[port]`. The local bypass tokens the
  /// platform understands are merged over the user values captured in
  /// [before]; the user list is never replaced.
  Future<void> apply({required int port, required SystemProxyRead before});

  /// Writes the values captured in [snapshot] back unchanged.
  Future<void> restore(SystemProxyRead snapshot);

  /// Turns only the proxy switch off; used when no snapshot exists to
  /// restore and the OS proxy was found pointing at our local port.
  Future<void> disable({required int port});
}

/// The backend for the current platform, or null where the OS has no system
/// proxy to manage (Android/iOS and unknown systems).
SystemProxyBackend? defaultSystemProxyBackend() {
  if (Platform.isLinux) return LinuxSystemProxyBackend();
  return null;
}
