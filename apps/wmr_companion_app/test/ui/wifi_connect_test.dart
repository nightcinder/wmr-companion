import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'raw_mode_notifier.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    FakeTransport wifi, {
    bool rawDefault = true,
    void Function(WmrWsEndpoint endpoint)? onEndpoint,
  }) async {
    final ble = UniversalBleTransport(
      adapter: FakeBleAdapter(),
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(ble),
          wifiTransportFactoryProvider.overrideWithValue((endpoint) {
            onEndpoint?.call(endpoint);
            return wifi;
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
}
