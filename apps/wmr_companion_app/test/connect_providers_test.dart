import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_ws/wmr_ws.dart';

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
}
