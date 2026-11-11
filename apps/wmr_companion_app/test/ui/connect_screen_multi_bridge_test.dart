import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/services/known_bridge_store.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'memory_known_bridge_store.dart';
import 'raw_mode_notifier.dart';

void main() {
  late FakeBleAdapter adapter;
  late UniversalBleTransport transport;

  Future<void> open(
    WidgetTester tester, {
    Future<List<WmrWsEndpoint>> Function()? discovery,
    KnownBridgeStore? store,
    FakeTransport? wifi,
    void Function(WmrWsEndpoint endpoint, bool composite)? onEndpoint,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    adapter = FakeBleAdapter();
    transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    final wifiTransport =
        wifi ??
        FakeTransport(
          devices: const [FakeDevice(id: '192.168.1.42:8765', mtu: 4096)],
        );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          streamModeProvider.overrideWith(RawModeNotifier.new),
          lanDiscoveryProvider.overrideWithValue(
            discovery ?? () async => const <WmrWsEndpoint>[],
          ),
          knownBridgeStoreProvider.overrideWithValue(
            store ?? MemoryKnownBridgeStore(),
          ),
          wifiTransportFactoryProvider.overrideWithValue((endpoint) {
            onEndpoint?.call(endpoint, false);
            return wifiTransport;
          }),
          compositeWifiTransportFactoryProvider.overrideWithValue((endpoint) {
            onEndpoint?.call(endpoint, true);
            return WifiLink(wifiTransport, activeLeg: () => WifiLinkLeg.tcp);
          }),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('launch scan deduplicates a dual-IP bridge and auto-connects', (
    tester,
  ) async {
    WmrWsEndpoint? seen;
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: '192.168.1.42:8765', mtu: 4096)],
    );
    await open(
      tester,
      discovery: () async => [
        WmrWsEndpoint(
          host: '192.168.1.42',
          port: 8765,
          bridgeId: 'bridge-1',
          name: 'WMR Bridge',
          candidateHosts: const ['192.168.1.43'],
        ),
      ],
      wifi: wifi,
      onEndpoint: (endpoint, _) => seen = endpoint,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(find.byKey(const Key('wifi-lan-row-bridge-1')), findsOneWidget);
    expect(find.textContaining('also 192.168.1.43'), findsOneWidget);
    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.text('Endpoint: 192.168.1.42:8765'), findsOneWidget);
    expect(seen?.hosts, ['192.168.1.42', '192.168.1.43']);

    await close(tester);
  });

  testWidgets('auto-connects to the remembered bridge among several', (
    tester,
  ) async {
    final store = MemoryKnownBridgeStore(
      const KnownBridge(
        bridgeId: 'bridge-2',
        hosts: ['192.168.1.50', '192.168.1.51'],
        port: 8765,
        bleFallback: false,
      ),
    );
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: '192.168.1.50:8765', mtu: 4096)],
    );
    var usedComposite = false;
    await open(
      tester,
      discovery: () async => [
        WmrWsEndpoint(
          host: '192.168.1.42',
          port: 8765,
          bridgeId: 'bridge-1',
          name: 'WMR Bridge One',
        ),
        WmrWsEndpoint(
          host: '192.168.1.50',
          port: 8765,
          bridgeId: 'bridge-2',
          name: 'WMR Bridge Two',
          candidateHosts: const ['192.168.1.51'],
        ),
      ],
      store: store,
      wifi: wifi,
      onEndpoint: (_, composite) => usedComposite |= composite,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.text('Endpoint: 192.168.1.50:8765'), findsOneWidget);
    expect(usedComposite, isFalse);
    expect(store.saved?.bridgeId, 'bridge-2');
    expect(store.saved?.bleFallback, isFalse);

    await close(tester);
  });

  testWidgets('auto-connects to the remembered host when discovery is empty', (
    tester,
  ) async {
    WmrWsEndpoint? seen;
    final store = MemoryKnownBridgeStore(
      const KnownBridge(
        bridgeId: 'bridge-3',
        hosts: ['192.168.1.60', '192.168.1.61'],
        port: 8765,
      ),
    );
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: '192.168.1.60:8765', mtu: 4096)],
    );
    await open(
      tester,
      store: store,
      wifi: wifi,
      onEndpoint: (endpoint, _) => seen = endpoint,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.text('Endpoint: 192.168.1.60:8765'), findsOneWidget);
    expect(seen?.bridgeId, 'bridge-3');
    expect(seen?.hosts, ['192.168.1.60', '192.168.1.61']);

    await close(tester);
  });

  testWidgets('several discovered bridges without a memory wait for a tap', (
    tester,
  ) async {
    await open(
      tester,
      discovery: () async => [
        WmrWsEndpoint(
          host: '192.168.1.42',
          port: 8765,
          bridgeId: 'bridge-1',
          name: 'WMR Bridge One',
        ),
        WmrWsEndpoint(
          host: '192.168.1.50',
          port: 8765,
          bridgeId: 'bridge-2',
          name: 'WMR Bridge Two',
        ),
      ],
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.text('State: idle'), findsOneWidget);

    await tester.tap(find.text('Wi-Fi'));
    await tester.pump();
    expect(find.byKey(const Key('wifi-lan-row-bridge-1')), findsOneWidget);
    expect(find.byKey(const Key('wifi-lan-row-bridge-2')), findsOneWidget);

    await close(tester);
  });

  testWidgets('discovers and connects to multiple bridges concurrently', (
    tester,
  ) async {
    await open(tester);

    // Start scan
    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();

    // Emit two bridges
    adapter.emitScanResult(
      const BleScanResult(
        deviceId: fakeBridgeLeftDeviceId,
        name: 'WMR Bridge Left',
        rssi: -45,
      ),
    );
    adapter.emitScanResult(
      const BleScanResult(
        deviceId: fakeBridgeRightDeviceId,
        name: 'WMR Bridge Right',
        rssi: -50,
      ),
    );
    await tester.pump();

    expect(find.text('WMR Bridge Left'), findsOneWidget);
    expect(find.text('WMR Bridge Right'), findsOneWidget);

    // Connect to both bridges concurrently without awaiting the first
    final connectButtons = find.text('Connect');
    expect(connectButtons, findsNWidgets(2));
    await tester.tap(connectButtons.first);
    await tester.pump();

    // Tap second bridge's Connect button while Left is in-flight
    await tester.tap(find.text('Connect').last);
    await tester.pump();

    // Allow both overlapping handshakes to complete
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();

    // Both bridges connect concurrently and reach ready
    expect(
      find.text('State: connected, streaming (2 bridges)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Bridge $fakeBridgeLeftDeviceId: MTU 185'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Bridge $fakeBridgeRightDeviceId: MTU 185'),
      findsOneWidget,
    );
    expect(find.text('Disconnect bridge'), findsNWidgets(2));
    expect(find.text('Disconnect all'), findsOneWidget);

    // Dual-drop auto-reconnect: both bridges drop simultaneously
    adapter.dropLink();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();

    expect(
      find.text('State: connected, streaming (2 bridges)'),
      findsOneWidget,
    );
    expect(find.text('Disconnect bridge'), findsNWidgets(2));
    expect(find.text('Disconnect all'), findsOneWidget);

    // Disconnect Left bridge individually
    await tester.tap(find.text('Disconnect bridge').first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // Right bridge remains connected
    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.text('Disconnect bridge'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    // Disconnect remaining bridge via main Disconnect button
    await tester.tap(find.text('Disconnect'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('State: disconnected'), findsOneWidget);
    expect(find.text('Connect'), findsNWidgets(2));

    await close(tester);
  });
}
