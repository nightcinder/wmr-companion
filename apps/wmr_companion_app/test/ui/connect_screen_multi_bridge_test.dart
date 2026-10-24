import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';

import 'raw_mode_notifier.dart';

void main() {
  late FakeBleAdapter adapter;
  late UniversalBleTransport transport;

  Future<void> open(WidgetTester tester) async {
    adapter = FakeBleAdapter();
    transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          streamModeProvider.overrideWith(RawModeNotifier.new),
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
