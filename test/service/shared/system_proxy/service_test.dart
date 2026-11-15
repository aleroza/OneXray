import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/system_proxy/system_proxy_backend.dart';
import 'package:onexray/core/system_proxy/system_proxy_models.dart';
import 'package:onexray/service/shared/system_proxy/service.dart';
import 'package:onexray/service/shared/system_proxy/snapshot_store.dart';

import '../../../support/test_directory.dart';

/// Records one backend the tests drive by hand: values, injected failures and
/// gate completers that expose the serial queue.
class _FakeBackend implements SystemProxyBackend {
  _FakeBackend({this.id = 'fake'});

  @override
  final String id;

  SystemProxyRead current = const SystemProxyRead(
    enabled: false,
    host: null,
    port: null,
    bypass: ['user.example'],
    values: {'mode': "'none'"},
  );

  Object? failure;
  Object? restoreFailure;
  int reads = 0;
  SystemProxyRead? appliedBefore;
  int? appliedPort;
  SystemProxyRead? restoredFrom;
  int? disabledPort;
  Completer<void>? gateOpen;
  final started = <String>[];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SystemProxyRead> read() async {
    reads++;
    return current;
  }

  @override
  Future<void> apply({required int port, required SystemProxyRead before}) async {
    started.add('apply');
    await gateOpen?.future;
    if (failure case final error?) throw error;
    appliedBefore = before;
    appliedPort = port;
    current = SystemProxyRead(
      enabled: true,
      host: '127.0.0.1',
      port: port,
      bypass: mergeProxyBypass(before.bypass, const ['localhost']),
      values: const {'mode': "'manual'"},
    );
  }

  @override
  Future<void> restore(SystemProxyRead snapshot) async {
    started.add('restore');
    await gateOpen?.future;
    if (restoreFailure case final error?) throw error;
    if (failure case final error?) throw error;
    restoredFrom = snapshot;
    current = snapshot;
  }

  @override
  Future<void> disable({required int port}) async {
    started.add('disable');
    if (failure case final error?) throw error;
    disabledPort = port;
    current = SystemProxyRead(
      enabled: false,
      host: null,
      port: null,
      bypass: current.bypass,
      values: const {'mode': "'none'"},
    );
  }
}

void main() {
  late Directory directory;
  late _FakeBackend backend;
  late SystemProxyService service;
  late bool portInUse;

  setUp(() async {
    directory = await createTestDirectory('onexray-system-proxy-');
    backend = _FakeBackend();
    portInUse = false;
    service = SystemProxyService(
      backendFactory: () => backend,
      store: SystemProxySnapshotStore(directory: () async => directory.path),
      portInUse: (_) async => portInUse,
    );
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<SystemProxySnapshot?> stored() =>
      SystemProxySnapshotStore(directory: () async => directory.path).read();

  test('apply captures the user values exactly once', () async {
    expect(await service.apply(10808), isNull);
    expect(backend.appliedBefore?.bypass, ['user.example']);
    expect(backend.appliedPort, 10808);
    final snapshot = await stored();
    expect(snapshot?.backendId, 'fake');
    expect(snapshot?.read.bypass, ['user.example']);

    expect(await service.apply(10809), isNull);
    expect(backend.reads, 1);
    expect(backend.appliedPort, 10809);
    expect(backend.appliedBefore?.bypass, ['user.example']);
  });

  test('a failed apply keeps the snapshot so remove still rolls back',
      () async {
    backend.failure = const SystemProxyFailure('gsettings refused');
    expect(await service.apply(10808), contains('gsettings refused'));
    expect(await stored(), isNotNull);

    backend.failure = null;
    expect(await service.remove(), isNull);
    expect(backend.restoredFrom?.bypass, ['user.example']);
    expect(await stored(), isNull);
  });

  test('remove without a prior apply never touches the backend', () async {
    expect(await service.remove(), isNull);
    expect(backend.started, isEmpty);
    expect(backend.reads, 0);
  });

  test('errors are returned as reasons and never thrown', () async {
    backend.failure = StateError('registry hive locked');
    expect(await service.apply(10808), contains('registry hive locked'));
    expect(await service.remove(), contains('registry hive locked'));
    await expectLater(
      service.clearStaleProxy(port: 10808, intentEnabled: true),
      completes,
    );
  });

  test('apply and stop run one at a time on the queue', () async {
    final gate = Completer<void>();
    backend.gateOpen = gate;
    final applying = service.apply(10808);
    while (backend.started.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final removing = service.remove();
    await Future<void>.delayed(Duration.zero);
    expect(backend.started, ['apply'], reason: 'stop must wait for apply');

    gate.complete();
    backend.gateOpen = null;
    expect(await applying, isNull);
    expect(await removing, isNull);
    expect(backend.started, ['apply', 'restore']);
  });

  test('a snapshot survives into a new service instance', () async {
    expect(await service.apply(10808), isNull);
    final restartedStore = SystemProxySnapshotStore(
      directory: () async => directory.path,
    );
    final restarted = SystemProxyService(
      backendFactory: () => backend,
      store: restartedStore,
      portInUse: (_) async => false,
    );
    // A restarted app resolves the directory during startup cleanup before
    // any later quit reaches remove().
    await restartedStore.read();

    expect(await restarted.remove(), isNull);
    expect(backend.restoredFrom?.bypass, ['user.example']);
  });

  test('a snapshot from another backend is never restored blindly', () async {
    expect(await service.apply(10808), isNull);
    final other = SystemProxyService(
      backendFactory: () => _FakeBackend(id: 'other'),
      store: SystemProxySnapshotStore(directory: () async => directory.path),
      portInUse: (_) async => false,
    );

    expect(await other.apply(10808), contains('fake backend'));
    expect(await other.remove(), contains('restore'));
    expect(await stored(), isNotNull);
  });

  group('clearStaleProxy', () {
    Future<void> leaveApplied() async {
      expect(await service.apply(10808), isNull);
    }

    test('restores our stale proxy when nothing listens on the port',
        () async {
      await leaveApplied();
      expect(backend.current.pointsAtLocalProxy(10808), isTrue);

      await service.clearStaleProxy(port: 10808, intentEnabled: true);

      expect(backend.started, ['apply', 'restore']);
      expect(await stored(), isNull);
    });

    test('leaves the proxy alone while the managed port is busy', () async {
      await leaveApplied();
      portInUse = true;

      await service.clearStaleProxy(port: 10808, intentEnabled: true);

      expect(backend.started, ['apply']);
      expect(await stored(), isNotNull);
    });

    test('never touches a proxy aimed at another address', () async {
      backend.current = const SystemProxyRead(
        enabled: true,
        host: 'proxy.corp',
        port: 3128,
        bypass: [],
        values: {},
      );

      await service.clearStaleProxy(port: 10808, intentEnabled: true);

      expect(backend.started, isEmpty);
    });

    test('without an intent or a snapshot it does not even read', () async {
      await service.clearStaleProxy(port: 10808, intentEnabled: false);
      expect(backend.reads, 0);
    });

    test('disables a foreign proxy pointing at our port without a snapshot',
        () async {
      backend.current = const SystemProxyRead(
        enabled: true,
        host: '127.0.0.1',
        port: 10808,
        bypass: [],
        values: {},
      );

      await service.clearStaleProxy(port: 10808, intentEnabled: true);

      expect(backend.disabledPort, 10808);
    });

    test('a stale snapshot from another backend still gets the proxy off',
        () async {
      await SystemProxySnapshotStore(
        directory: () async => directory.path,
      ).write(
        const SystemProxySnapshot(
          'other',
          SystemProxyRead(
            enabled: false,
            host: null,
            port: null,
            bypass: [],
            values: {},
          ),
        ),
      );
      backend.current = const SystemProxyRead(
        enabled: true,
        host: '127.0.0.1',
        port: 10808,
        bypass: [],
        values: {},
      );

      await service.clearStaleProxy(port: 10808, intentEnabled: true);

      // The proxy provably points at our port, so it is switched off even
      // though only the foreign backend could restore it byte for byte.
      expect(backend.disabledPort, 10808);
      expect(await stored(), isNull, reason: 'the foreign snapshot is dropped');
    });
  });

  test('no backend on this platform means silent no-ops', () async {
    final mobile = SystemProxyService(
      backendFactory: () => null,
      store: SystemProxySnapshotStore(directory: () async => directory.path),
      portInUse: (_) async => false,
    );

    expect(await mobile.apply(10808), contains('no system proxy support'));
    expect(await mobile.remove(), isNull);
    await expectLater(
      mobile.clearStaleProxy(port: 10808, intentEnabled: true),
      completes,
    );
  });

  test('a directory that never answers times out into a reason', () async {
    // Reproduces the wedged platform channel: the future never completes.
    final wedged = SystemProxySnapshotStore(
      directory: () => Completer<String>().future,
    );
    final wedgedService = SystemProxyService(
      backendFactory: () => backend,
      store: wedged,
      portInUse: (_) async => false,
    );

    final applyFailure = await wedgedService.apply(10808);
    expect(applyFailure, contains('timed out'));
    // The cached verdict makes every later call instant and finite.
    expect(await wedgedService.remove(), contains('timed out'));
    expect(backend.started, isEmpty);
  });

  test('a failing directory is cached and reported as a reason', () async {
    final broken = SystemProxySnapshotStore(
      directory: () async => throw StateError('no path provider'),
    );
    final brokenService = SystemProxyService(
      backendFactory: () => backend,
      store: broken,
      portInUse: (_) async => false,
    );

    expect(await brokenService.apply(10808), contains('no path provider'));
    expect(await brokenService.remove(), contains('no path provider'));
  });

  test('an unreadable snapshot still switches the remembered port off',
      () async {
    final snapshotFile = File('${directory.path}/system-proxy-snapshot.json');
    expect(await service.apply(10808), isNull);
    // The only copy of the user values is damaged after the apply.
    await snapshotFile.writeAsString('{ not json');

    final reason = await service.remove();

    expect(reason, isNotNull);
    expect(backend.disabledPort, 10808, reason: 'fallback disable');
    expect(await snapshotFile.exists(), isTrue,
        reason: 'the snapshot survives for a later byte-for-byte restore');
  });

  test('a failing apply still knows the port to disable', () async {
    // The apply writes part of its plan and then fails; the port must have
    // been remembered before backend.apply started, or a later remove()
    // with an unreadable snapshot could not switch the proxy off.
    backend.failure = const SystemProxyFailure('half written');
    expect(await service.apply(10808), contains('half written'));
    backend.failure = null;
    await File('${directory.path}/system-proxy-snapshot.json')
        .writeAsString('{ not json');

    final reason = await service.remove();

    expect(reason, isNotNull);
    expect(backend.disabledPort, 10808,
        reason: 'the port was captured before the failing backend.apply');
  });

  test('a failing restore disables the port and keeps the snapshot',
      () async {
    expect(await service.apply(10808), isNull);
    backend.restoreFailure = StateError('restore denied');

    final reason = await service.remove();

    expect(reason, contains('restore denied'));
    expect(backend.started, ['apply', 'restore', 'disable']);
    expect(await stored(), isNotNull);
  });
}
