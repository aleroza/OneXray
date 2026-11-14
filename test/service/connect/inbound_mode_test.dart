import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/core/ffi/windows/mode.dart';
import 'package:onexray/service/advanced/platform_policy.dart';
import 'package:onexray/service/connect/compiler.dart';
import 'package:onexray/service/connect/routing/region_catalog.dart';
import 'package:onexray/service/connect/settings.dart';
import 'package:onexray/service/shared/xray/runtime_inbounds.dart';

final catalog = RegionCatalog.empty();

RuntimeOptions options({
  bool tunEnabled = true,
  bool socksEnabled = false,
  int localSocksPort = 10808,
  bool keepConfigInbounds = true,
  ConnectionPlatform platform = ConnectionPlatform.linux,
}) => RuntimeOptions(
  platform: platform,
  windowsMode: WindowsMode.exe,
  sessionDirectory: '/unused-session',
  metricsPort: 18186,
  socksPort: 18187,
  interfaceName: 'Ethernet',
  tunEnabled: tunEnabled,
  socksEnabled: socksEnabled,
  localSocksPort: localSocksPort,
  keepConfigInbounds: keepConfigInbounds,
);

Map<String, dynamic> compileNormal({
  bool tunEnabled = true,
  bool socksEnabled = false,
  int localSocksPort = 10808,
}) => ConnectionCompiler.compile(
  settings: ConnectionSettings(),
  entries: [
    ResolvedServer(
      id: 1,
      sourceId: 1,
      outbound: {'protocol': 'freedom', 'tag': 'node'},
    ),
  ],
  regions: catalog,
  options: options(
    tunEnabled: tunEnabled,
    socksEnabled: socksEnabled,
    localSocksPort: localSocksPort,
  ),
).config;

Map<String, dynamic> compileRaw(
  Map<String, dynamic> raw, {
  bool tunEnabled = true,
  bool socksEnabled = false,
  int localSocksPort = 10808,
  bool keepConfigInbounds = true,
}) => ConnectionCompiler.compile(
  settings: ConnectionSettings(expert: true),
  entries: const [],
  raw: raw,
  regions: catalog,
  options: options(
    tunEnabled: tunEnabled,
    socksEnabled: socksEnabled,
    localSocksPort: localSocksPort,
    keepConfigInbounds: keepConfigInbounds,
  ),
).config;

void main() {
  test('the managed TUN inbound stays the default', () {
    final inbounds = compileNormal()['inbounds'] as List;
    expect(inbounds, hasLength(1));
    expect(inbounds.first['tag'], 'tunIn');
    expect(inbounds.first['protocol'], 'tun');
  });

  test('the SOCKS port replaces the managed TUN inbound', () {
    final inbounds =
        compileNormal(tunEnabled: false, socksEnabled: true)['inbounds']
            as List;
    expect(inbounds, hasLength(1));
    expect(inbounds.first['tag'], 'tunIn');
    expect(inbounds.first['protocol'], 'socks');
    expect(inbounds.first['listen'], '127.0.0.1');
    expect(inbounds.first['port'], '10808');
  });

  test('the TUN tunnel and the SOCKS port stay independent', () {
    final inbounds =
        compileNormal(tunEnabled: true, socksEnabled: true)['inbounds'] as List;
    expect(inbounds, hasLength(2));
    expect(inbounds.first['tag'], 'tunIn');
    expect(inbounds.first['protocol'], 'tun');
    expect(inbounds.last['tag'], socksInboundTag);
    expect(inbounds.last['protocol'], 'socks');
    expect(inbounds.last['port'], '10808');
  });

  test('the managed SOCKS port takes over the tunnel tag', () {
    final config = compileNormal(tunEnabled: false, socksEnabled: true);
    final rules = (config['routing'] as Map)['rules'] as List;
    final tunnel = rules.firstWhere(
      (rule) => rule['ruleTag'] == 'app-tunnel-dns',
    );
    expect(tunnel['inboundTag'], ['tunIn']);
  });

  test('a configuration without any inbound is rejected', () {
    expect(
      () => compileNormal(tunEnabled: false, socksEnabled: false),
      throwsFormatException,
    );
  });

  test('the SOCKS port replaces the source tunIn in a Raw configuration', () {
    final raw = <String, dynamic>{
      'inbounds': [
        {
          'tag': 'tunIn',
          'protocol': 'tun',
          'settings': {'mtu': 1400},
        },
      ],
      'outbounds': [
        {'protocol': 'freedom'},
      ],
    };
    final inbounds =
        compileRaw(raw, tunEnabled: false, socksEnabled: true)['inbounds']
            as List;
    expect(inbounds, hasLength(1));
    expect(inbounds.first['tag'], 'tunIn');
    expect(inbounds.first['protocol'], 'socks');
    expect(inbounds.first['port'], '10808');
  });

  test(
    'the source inbounds are dropped when the configuration switch is off',
    () {
      final raw = <String, dynamic>{
        'inbounds': [
          {'tag': 'user-socks', 'protocol': 'socks', 'port': '11020'},
        ],
        'outbounds': [
          {'protocol': 'freedom'},
        ],
      };
      final kept = compileRaw(raw)['inbounds'] as List;
      expect(kept.any((inbound) => inbound['tag'] == 'user-socks'), isTrue);
      final dropped =
          compileRaw(raw, keepConfigInbounds: false)['inbounds'] as List;
      expect(dropped.any((inbound) => inbound['tag'] == 'user-socks'), isFalse);
      expect(dropped.any((inbound) => inbound['tag'] == 'tunIn'), isTrue);
    },
  );

  test(
    'the source inbounds are the only ingress without a managed inbound',
    () {
      final raw = <String, dynamic>{
        'inbounds': [
          {'tag': 'user-socks', 'protocol': 'socks', 'port': '11020'},
        ],
        'outbounds': [
          {'protocol': 'freedom'},
        ],
      };
      final inbounds =
          compileRaw(raw, tunEnabled: false, socksEnabled: false)['inbounds']
              as List;
      expect(inbounds, hasLength(1));
      expect(inbounds.first['tag'], 'user-socks');
    },
  );

  test('the MSIX build keeps its private SOCKS tunnel', () {
    final config = ConnectionCompiler.compile(
      settings: ConnectionSettings(),
      entries: [
        ResolvedServer(
          id: 1,
          sourceId: 1,
          outbound: {'protocol': 'freedom', 'tag': 'node'},
        ),
      ],
      regions: catalog,
      options: RuntimeOptions(
        platform: ConnectionPlatform.windows,
        windowsMode: WindowsMode.msix,
        sessionDirectory: '/unused-session',
        metricsPort: 18186,
        socksPort: 18187,
        interfaceName: 'Ethernet',
        tunEnabled: false,
        socksEnabled: true,
        localSocksPort: 10808,
      ),
    ).config;
    final inbounds = config['inbounds'] as List;
    expect(inbounds, hasLength(2));
    expect(inbounds.first['tag'], 'tunIn');
    expect(inbounds.first['protocol'], 'socks');
    expect(inbounds.first['port'], '18187');
    expect(inbounds.last['tag'], socksInboundTag);
    expect(inbounds.last['port'], '10808');
  });

  test('the SOCKS port rejects a conflicting runtime port', () {
    expect(
      () => RuntimeOptions(
        platform: ConnectionPlatform.linux,
        sessionDirectory: '/unused-session',
        metricsPort: 10808,
        socksPort: 18187,
        interfaceName: 'Ethernet',
        socksEnabled: true,
        localSocksPort: 10808,
      ),
      throwsFormatException,
    );
  });

  test('the platform policy keeps the current behavior by default', () {
    final policy = PlatformPolicy.defaults();
    expect(policy.tunEnabled, isTrue);
    expect(policy.socksEnabled, isFalse);
    expect(policy.socksPort, 10808);
    expect(policy.keepConfigInbounds, isTrue);
  });

  test('the platform policy reads the managed ingress switches', () {
    final policy = PlatformPolicy.fromJson({
      'inbound': {
        'tunEnabled': false,
        'socksEnabled': true,
        'socksPort': 20808,
        'keepConfigInbounds': false,
      },
    });
    expect(policy.tunEnabled, isFalse);
    expect(policy.socksEnabled, isTrue);
    expect(policy.socksPort, 20808);
    expect(policy.keepConfigInbounds, isFalse);
  });

  test('the platform policy rejects an invalid SOCKS port', () {
    expect(
      () => PlatformPolicy.fromJson({
        'inbound': {'socksPort': 80},
      }),
      throwsFormatException,
    );
  });

  test('the platform policy rejects an unknown managed ingress field', () {
    expect(
      () => PlatformPolicy.fromJson({
        'inbound': {'unknown': true},
      }),
      throwsFormatException,
    );
  });
}
