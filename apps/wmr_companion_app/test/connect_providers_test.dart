import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';

import 'ui/raw_mode_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer({
    BleTransport Function(WmrWsEndpoint)? wifiFactory,
    WifiLink Function(WmrWsEndpoint)? compositeFactory,
    Future<List<WmrWsEndpoint>> Function()? discovery,
  }) {
    final ble = UniversalBleTransport(
      adapter: FakeBleAdapter(),
      scanTimeout: const Duration(minutes: 5),
    );
    final container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(ble),
        wifiTransportFactoryProvider.overrideWithValue(
          wifiFactory ?? (_) => FakeTransport(),
        ),
        compositeWifiTransportFactoryProvider.overrideWithValue(
          compositeFactory ?? (_) => WifiLink(FakeTransport()),
        ),
        lanDiscoveryProvider.overrideWithValue(
          discovery ?? () async => const [],
        ),
        streamModeProvider.overrideWith(RawModeNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  FakeTransport wifiWithDevice(String id) =>
      FakeTransport(devices: [FakeDevice(id: id, mtu: 4096)]);

  test('a direct Wi-Fi connect does not build the composite', () async {
    var compositeBuilds = 0;
    final container = makeContainer(
      wifiFactory: (_) => wifiWithDevice('pi.local:8765'),
      compositeFactory: (_) {
        compositeBuilds++;
        return WifiLink(FakeTransport());
      },
    );

    await container
        .read(realDeviceProvider.notifier)
        .connectWifi(host: 'pi.local', port: 8765);

    final state = container.read(realDeviceProvider);
    expect(state.connected, isTrue);
    expect(state.activeTransport, BridgeTransportKind.wifi);
    expect(state.wifiFallback, isFalse);
    expect(state.wifiLeg, isNull);
    expect(compositeBuilds, 0);
  });

  test('LAN discovery publishes the endpoints it finds', () async {
    final endpoint = WmrWsEndpoint(
      host: '192.168.1.42',
      port: 8765,
      bridgeId: 'pi-1',
      name: 'LAN Bridge',
    );
    final container = makeContainer(discovery: () async => [endpoint]);

    await container.read(realDeviceProvider.notifier).discoverLan();

    final state = container.read(realDeviceProvider);
    expect(state.lanEndpoints, [endpoint]);
    expect(state.discoveringLan, isFalse);
    expect(state.lanError, isNull);
  });

  test(
    'fallback connects through the composite and reports its active leg',
    () async {
      var compositeBuilds = 0;
      var leg = WifiLinkLeg.tcp;
      final container = makeContainer(
        wifiFactory: (_) =>
            throw StateError('direct Wi-Fi factory must not run'),
        compositeFactory: (_) {
          compositeBuilds++;
          return WifiLink(
            wifiWithDevice('192.168.1.42:8765'),
            activeLeg: () => leg,
          );
        },
      );

      await container
          .read(realDeviceProvider.notifier)
          .connectWifi(
            host: '192.168.1.42',
            port: 8765,
            bridgeId: 'pi-1',
            bleFallback: true,
          );

      var state = container.read(realDeviceProvider);
      expect(compositeBuilds, 1);
      expect(state.connected, isTrue);
      expect(state.wifiFallback, isTrue);
      expect(state.wifiLeg, WifiLinkLeg.tcp);

      // A failover keeps the connection state `connected`; a later update must
      // pick up the new leg.
      leg = WifiLinkLeg.ble;
      await container.read(realDeviceProvider.notifier).discoverLan();
      state = container.read(realDeviceProvider);
      expect(state.wifiLeg, WifiLinkLeg.ble);
    },
  );

  test('fallback scans and switches a real composite to its BLE leg', () async {
    const bridgeId = 'pi-1';
    const bleDeviceId = 'ble-pi-1';
    final endpoint = WmrWsEndpoint(
      host: '192.168.1.42',
      port: 8765,
      bridgeId: bridgeId,
    );
    final tcp = _FailingTcp(endpoint);
    final ble = FakeTransport(
      devices: const [
        FakeDevice(id: bleDeviceId, name: 'WMR Bridge', mtu: 244),
      ],
    );
    ble.onRead = (deviceId, characteristic) {
      if (characteristic == wmrBridgeVersionCharUuid) {
        return Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'wmr_ble_endpoint',
              'protocol': 1,
              'bridge_id': bridgeId,
              'name': 'WMR Bridge',
              'version': '0.2.4',
              'hosts': ['192.168.1.42'],
              'port': 8765,
              'path': '/wmr',
              'authRequired': false,
            }),
          ),
        );
      }
      throw StateError('unexpected read $characteristic');
    };
    final composite = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: Duration.zero,
      bleScanWait: const Duration(seconds: 2),
    );
    addTearDown(composite.dispose);

    final container = makeContainer(
      compositeFactory: (_) => WifiLink(
        composite,
        activeLeg: () =>
            switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
              CompositeLeg.tcp => WifiLinkLeg.tcp,
              CompositeLeg.ble => WifiLinkLeg.ble,
              null => null,
            },
      ),
    );

    await container
        .read(realDeviceProvider.notifier)
        .connectWifi(
          host: endpoint.host,
          port: endpoint.port,
          bridgeId: bridgeId,
          bleFallback: true,
        );

    final state = container.read(realDeviceProvider);
    expect(state.connected, isTrue);
    expect(state.wifiFallback, isTrue);
    expect(state.wifiLeg, WifiLinkLeg.ble);
    expect(composite.activeLegFor(endpoint.resolvedDeviceId), CompositeLeg.ble);
    expect(
      await ble.connectionState(bleDeviceId).first,
      BleConnectionState.connected,
    );
  });

  test('publishes the protocol the service read after connect', () async {
    const id = 'pi.local:8765';
    final transport = FakeTransport(
      devices: const [
        FakeDevice(
          id: id,
          services: [
            BleServiceInfo(
              uuid: wmrBridgeServiceUuid,
              characteristicUuids: [wmrBridgeVersionCharUuid],
            ),
          ],
        ),
      ],
    );
    transport.onRead = (_, characteristic) {
      if (characteristic.toLowerCase() != wmrBridgeVersionCharUuid) {
        throw StateError('unexpected read $characteristic');
      }
      return Uint8List.fromList(utf8.encode('0.3.19'));
    };
    final container = makeContainer(wifiFactory: (_) => transport);
    final read = Completer<String?>();
    container.listen(realDeviceProvider, (_, next) {
      if (!read.isCompleted && next.protocol != null) {
        read.complete(next.protocol!.firmwareVersion);
      }
    });

    await container
        .read(realDeviceProvider.notifier)
        .connectWifi(host: 'pi.local', port: 8765);

    expect(await read.future.timeout(const Duration(seconds: 2)), '0.3.19');
    expect(container.read(realDeviceProvider).protocolUnavailable, isFalse);
  });

  test(
    'publishes protocolUnavailable when discovery finds no bridge',
    () async {
      const id = 'pi.local:8765';
      final transport = FakeTransport(devices: const [FakeDevice(id: id)]);
      final container = makeContainer(wifiFactory: (_) => transport);
      final unavailable = Completer<void>();
      container.listen(realDeviceProvider, (_, next) {
        if (!unavailable.isCompleted && next.protocolUnavailable) {
          unavailable.complete();
        }
      });

      await container
          .read(realDeviceProvider.notifier)
          .connectWifi(host: 'pi.local', port: 8765);

      await unavailable.future.timeout(const Duration(seconds: 2));
      final state = container.read(realDeviceProvider);
      expect(state.protocol, isNull);
      expect(state.protocolUnavailable, isTrue);
    },
  );

  group('BridgeReleaseChecker', () {
    test(
      'parses the latest release tag and caches it for the session',
      () async {
        var fetches = 0;
        var now = DateTime(2026, 11, 10, 12);
        final checker = BridgeReleaseChecker(
          fetch: (_) async {
            fetches++;
            return '{"tag_name":"v0.3.20"}';
          },
          clock: () => now,
        );

        expect((await checker.latest())!.toString(), '0.3.20');
        expect((await checker.latest())!.toString(), '0.3.20');
        expect(fetches, 1, reason: 'the second read is served from the cache');

        now = now.add(const Duration(hours: 2));
        expect((await checker.latest())!.toString(), '0.3.20');
        expect(fetches, 2, reason: 'the cache expires after an hour');
      },
    );

    test(
      'degrades silently when offline or the response is unusable',
      () async {
        final offline = BridgeReleaseChecker(
          fetch: (_) async => throw StateError('offline'),
        );
        expect(await offline.latest(), isNull);

        final malformed = BridgeReleaseChecker(
          fetch: (_) async => '{"tag_name":24}',
        );
        expect(await malformed.latest(), isNull);
        expect(BridgeReleaseChecker.parseLatestRelease('not json'), isNull);
        expect(BridgeReleaseChecker.parseLatestRelease('[]'), isNull);
        expect(
          BridgeReleaseChecker.parseLatestRelease('{"tag_name":"v0.3.21"}')
              ?.toString(),
          '0.3.21',
        );
      },
    );
  });
}

/// A Wi-Fi leg that is reachable but refuses every dial, so the composite has
/// to use its BLE fallback.
class _FailingTcp extends WmrWsTransport {
  _FailingTcp(WmrWsEndpoint endpoint) : super(endpoints: [endpoint]);

  @override
  Future<void> connect(String deviceId) async =>
      throw StateError('tcp refused');
}
