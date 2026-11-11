import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/protocol/firmware_version.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'ui/raw_mode_notifier.dart';

void main() {
  testWidgets(
    'discovers a LAN bridge and connects over the opt-in BLE fallback',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final wifi = FakeTransport(
        devices: const [FakeDevice(id: '192.168.1.42:8765', mtu: 4096)],
      );
      var compositeBuilds = 0;
      WmrWsEndpoint? builtEndpoint;
      final ble = UniversalBleTransport(
        adapter: FakeBleAdapter(),
        scanTimeout: const Duration(minutes: 5),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            realTransportProvider.overrideWithValue(ble),
            streamModeProvider.overrideWith(RawModeNotifier.new),
            lanDiscoveryProvider.overrideWithValue(
              () async => [
                WmrWsEndpoint(
                  host: '192.168.1.42',
                  port: 8765,
                  bridgeId: 'pi-1',
                  name: 'LAN Bridge',
                  candidateHosts: ['192.168.1.43'],
                ),
              ],
            ),
            compositeWifiTransportFactoryProvider.overrideWithValue((endpoint) {
              compositeBuilds++;
              builtEndpoint = endpoint;
              return WifiLink(wifi, activeLeg: () => WifiLinkLeg.tcp);
            }),
            wifiTransportFactoryProvider.overrideWithValue(
              (_) => throw StateError('the direct Wi-Fi factory must not run'),
            ),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Wi-Fi'));
      await tester.pump();
      expect(find.byKey(const Key('wifi-discover')), findsOneWidget);
      expect(find.byKey(const Key('wifi-ble-fallback')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('wifi-discover')));
      await tester.tap(find.byKey(const Key('wifi-discover')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.text('LAN Bridge'), findsOneWidget);

      final fallback = find.byKey(const Key('wifi-ble-fallback'));
      await tester.ensureVisible(fallback);
      await tester.tap(fallback);
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

      expect(compositeBuilds, 1);
      // The discovered bridge's other interface reaches the transport, so a
      // failed primary host can fall back instead of the user losing the row.
      expect(builtEndpoint?.hosts, ['192.168.1.42', '192.168.1.43']);
      expect(find.text('State: connected, streaming'), findsOneWidget);
      expect(find.text('Endpoint: 192.168.1.42:8765'), findsOneWidget);
      expect(find.text('Active leg: TCP'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'shows a neutral active leg once the fallback link is disconnected',
    (tester) async {
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
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(_DisconnectedFallback.new),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Wi-Fi'));
      await tester.pump();
      expect(find.text('Active leg: -'), findsOneWidget);
      expect(find.text('Active leg: connecting'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('shows the connected bridge version and a newer-release banner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_ConnectedBridge.new),
          latestBridgeReleaseProvider.overrideWith(
            (ref) async => const WmrSemanticVersion(0, 3, 20),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Bridge version: 0.3.19'), findsOneWidget);
    expect(find.byKey(const Key('bridge-update-banner')), findsOneWidget);
    expect(find.textContaining('0.3.20'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('hides the update banner when the bridge is current', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          realDeviceProvider.overrideWith(_ConnectedBridge.new),
          latestBridgeReleaseProvider.overrideWith(
            (ref) async => const WmrSemanticVersion(0, 3, 19),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Bridge version: 0.3.19'), findsOneWidget);
    expect(find.byKey(const Key('bridge-update-banner')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets('labels a protocol that will never arrive as unavailable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pump({required bool unavailable}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            realDeviceProvider.overrideWith(
              () => _BridgeWithoutProtocol(unavailable: unavailable),
            ),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
    }

    await pump(unavailable: false);
    expect(find.text('Bridge version: reading…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await pump(unavailable: true);
    expect(
      find.text('Bridge version: unavailable (discovery failed)'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// A connected bridge whose protocol read has not landed, or never will.
class _BridgeWithoutProtocol extends RealDeviceController {
  _BridgeWithoutProtocol({required this.unavailable});

  final bool unavailable;

  @override
  RealDeviceState build() => RealDeviceState(
    status: const BleLinkStatus(BleLinkPhase.ready, deviceId: 'bridge-1'),
    deviceId: 'bridge-1',
    connectedDeviceIds: const {'bridge-1'},
    protocolUnavailable: unavailable,
  );
}

/// A connected bridge that has already reported its FF16 version.
class _ConnectedBridge extends RealDeviceController {
  @override
  RealDeviceState build() => const RealDeviceState(
    status: BleLinkStatus(BleLinkPhase.ready, deviceId: 'bridge-1'),
    deviceId: 'bridge-1',
    connectedDeviceIds: {'bridge-1'},
    protocol: WmrProtocolVersion(
      features: WmrBridgeFeatures.none,
      firmwareVersion: '0.3.19',
    ),
  );
}

/// A Wi-Fi fallback link that is no longer connected, as it is after the user
/// taps Disconnect.
class _DisconnectedFallback extends RealDeviceController {
  @override
  RealDeviceState build() => const RealDeviceState(
    activeTransport: BridgeTransportKind.wifi,
    wifiDeviceId: '192.168.1.42:8765',
    wifiFallback: true,
  );
}
