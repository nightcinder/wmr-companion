import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/services/bridge_token_store.dart';
import 'package:wmr_companion_app/services/known_bridge_store.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_ws/wmr_ws.dart';

import '../services/memory_secure_token_backend.dart';
import 'memory_known_bridge_store.dart';
import 'raw_mode_notifier.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    FakeTransport wifi, {
    bool rawDefault = true,
    Future<List<WmrWsEndpoint>> Function()? discovery,
    KnownBridgeStore? store,
    BridgeTokenStore? tokenStore,
    void Function(WmrWsEndpoint endpoint)? onEndpoint,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ble = UniversalBleTransport(
      adapter: FakeBleAdapter(),
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(ble),
          launchAutoConnectEnabledProvider.overrideWithValue(false),
          lanDiscoveryProvider.overrideWithValue(
            discovery ?? () async => const <WmrWsEndpoint>[],
          ),
          knownBridgeStoreProvider.overrideWithValue(
            store ?? MemoryKnownBridgeStore(),
          ),
          bridgeTokenStoreProvider.overrideWithValue(
            tokenStore ?? BridgeTokenStore(MemorySecureTokenBackend()),
          ),
          wifiTransportFactoryProvider.overrideWithValue((endpoint) {
            onEndpoint?.call(endpoint);
            return wifi;
          }),
          compositeWifiTransportFactoryProvider.overrideWithValue((endpoint) {
            onEndpoint?.call(endpoint);
            return WifiLink(wifi, activeLeg: () => WifiLinkLeg.tcp);
          }),
          if (rawDefault) streamModeProvider.overrideWith(RawModeNotifier.new),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Wi-Fi'));
    await tester.pump();
  }

  testWidgets('host:port and token entry connects to a Wi-Fi bridge', (
    tester,
  ) async {
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    await open(tester, wifi);

    expect(find.byKey(const Key('wifi-host')), findsOneWidget);
    expect(find.byKey(const Key('wifi-port')), findsOneWidget);
    expect(find.byKey(const Key('wifi-token')), findsOneWidget);
    expect(find.byKey(const Key('wifi-secure')), findsOneWidget);
    expect(find.textContaining('cleartext'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('wifi-host')), 'pi.local');
    await tester.enterText(find.byKey(const Key('wifi-port')), '8765');
    await tester.enterText(
      find.byKey(const Key('wifi-token')),
      'shared-secret',
    );
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.text('Endpoint: pi.local:8765'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConnectScreen)),
    );
    expect(
      container.read(bridgeTransportKindsProvider)['pi.local:8765'],
      BridgeTransportKind.wifi,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('rejects an empty host and a bad port before connecting', (
    tester,
  ) async {
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: 'pi.local:8765')],
    );
    await open(tester, wifi);

    await tester.enterText(find.byKey(const Key('wifi-host')), '  ');
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.pump();
    expect(find.text('Enter the bridge host or IP address.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('wifi-host')), 'pi.local');
    await tester.enterText(find.byKey(const Key('wifi-port')), '70000');
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.pump();
    expect(
      find.text('Port must be a number between 1 and 65535.'),
      findsOneWidget,
    );
  });

  testWidgets('switching to Bluetooth disconnects the Wi-Fi bridge', (
    tester,
  ) async {
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    await open(tester, wifi);

    await tester.enterText(find.byKey(const Key('wifi-host')), 'pi.local');
    await tester.enterText(find.byKey(const Key('wifi-port')), '8765');
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('State: connected, streaming'), findsOneWidget);

    await tester.ensureVisible(find.text('Bluetooth'));
    await tester.pump();
    await tester.tap(find.text('Bluetooth'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.text('State: idle'), findsOneWidget);
    expect(find.byKey(const Key('wifi-host')), findsNothing);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  testWidgets('TLS switch builds a wss endpoint', (tester) async {
    WmrWsEndpoint? seen;
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    await open(tester, wifi, onEndpoint: (endpoint) => seen = endpoint);

    await tester.enterText(find.byKey(const Key('wifi-host')), 'pi.local');
    await tester.enterText(find.byKey(const Key('wifi-port')), '8765');
    await tester.tap(find.byKey(const Key('wifi-secure')));
    await tester.pump();
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(seen, isNotNull);
    expect(seen!.secure, isTrue);
    expect(seen!.uri.scheme, 'wss');
    expect(find.textContaining('cleartext'), findsNothing);
  });

  testWidgets(
    'connecting to a discovered bridge remembers it for next launch',
    (tester) async {
      final store = MemoryKnownBridgeStore();
      final endpoint = WmrWsEndpoint(
        host: '192.168.1.42',
        port: 8765,
        bridgeId: 'bridge-1',
        name: 'LAN Bridge',
      );
      final wifi = FakeTransport(
        devices: const [FakeDevice(id: '192.168.1.42:8765', mtu: 4096)],
      );
      await open(tester, wifi, store: store, discovery: () async => [endpoint]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('wifi-discover')));
      await tester.tap(find.byKey(const Key('wifi-discover')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      final connect = find.byKey(
        const Key('wifi-lan-connect-192.168.1.42:8765'),
      );
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(find.text('State: connected, streaming'), findsOneWidget);
      expect(store.saved?.bridgeId, 'bridge-1');
      expect(store.saved?.hosts, ['192.168.1.42']);
      expect(store.saved?.port, 8765);
      expect(store.saved?.bleFallback, isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('switching from BLE to Wi-Fi hides the old BLE endpoint', (
    tester,
  ) async {
    final adapter = FakeBleAdapter();
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: 'pi.local:8765')],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(
            UniversalBleTransport(
              adapter: adapter,
              scanTimeout: const Duration(minutes: 5),
            ),
          ),
          wifiTransportFactoryProvider.overrideWithValue((_) => wifi),
          compositeWifiTransportFactoryProvider.overrideWithValue(
            (_) => WifiLink(wifi, activeLeg: () => WifiLinkLeg.tcp),
          ),
          launchAutoConnectEnabledProvider.overrideWithValue(false),
          lanDiscoveryProvider.overrideWithValue(
            () async => const <WmrWsEndpoint>[],
          ),
          knownBridgeStoreProvider.overrideWithValue(MemoryKnownBridgeStore()),
          streamModeProvider.overrideWith(RawModeNotifier.new),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();
    adapter.emitScanResult(
      const BleScanResult(
        deviceId: fakeBridgeDeviceId,
        name: 'WMR Bridge',
        rssi: -48,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.textContaining('Endpoint:'), findsNothing);

    await tester.tap(find.text('Wi-Fi'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.textContaining('Endpoint:'), findsNothing);
    expect(find.text('State: idle'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('remembers a typed token and reuses it with an empty field', (
    tester,
  ) async {
    final backend = MemorySecureTokenBackend();
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    WmrWsEndpoint? seen;
    await open(
      tester,
      wifi,
      tokenStore: BridgeTokenStore(backend),
      onEndpoint: (endpoint) => seen = endpoint,
    );

    await tester.enterText(find.byKey(const Key('wifi-host')), 'pi.local');
    await tester.enterText(
      find.byKey(const Key('wifi-token')),
      'shared-secret',
    );
    await tester.ensureVisible(find.byKey(const Key('wifi-remember-token')));
    await tester.tap(find.byKey(const Key('wifi-remember-token')));
    await tester.pump();
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(backend.values.values, contains('shared-secret'));

    // Bluetooth is off on the next attempt, so the field is empty and the
    // saved token has to authenticate the same host.
    seen = null;
    await tester.enterText(find.byKey(const Key('wifi-token')), '');
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(seen?.token, 'shared-secret');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('does not save a typed token without the opt-in', (tester) async {
    final backend = MemorySecureTokenBackend();
    final wifi = FakeTransport(
      devices: const [FakeDevice(id: 'pi.local:8765', mtu: 4096)],
    );
    await open(tester, wifi, tokenStore: BridgeTokenStore(backend));

    await tester.enterText(find.byKey(const Key('wifi-host')), 'pi.local');
    await tester.enterText(
      find.byKey(const Key('wifi-token')),
      'shared-secret',
    );
    await tester.ensureVisible(find.text('Connect over Wi-Fi'));
    await tester.pump();
    await tester.tap(find.text('Connect over Wi-Fi'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(backend.values, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  test('a missing token names the file on the Pi', () {
    expect(
      wifiFailureMessage(
        const WmrWsAuthException(
          WmrWsAuthFailure.noToken,
          'the daemon requires a token but the endpoint has none',
        ),
      ),
      contains('/etc/wmr-bridge/token'),
    );
  });
}
