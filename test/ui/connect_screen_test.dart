import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/ble_adapter.dart';
import 'package:wmr_companion/ble/ble_transport.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/ble/universal_ble_transport.dart';
import 'package:wmr_companion/ui/connect/connect_providers.dart';
import 'package:wmr_companion/ui/connect/connect_screen.dart';

import '../ble/fake_adapter.dart';

void main() {
  late FakeAdapter adapter;

  Future<void> open(WidgetTester tester) async {
    adapter = FakeAdapter();
    final transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [realTransportProvider.overrideWithValue(transport)],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.tap(find.text('Real device'));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('scan, connect and show MTU and stream counters', (tester) async {
    await open(tester);

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
    expect(find.text('WMR Bridge'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    // Stream cancellation needs a real event-loop turn, not just microtasks.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.textContaining('MTU (negotiated): 185'), findsOneWidget);
    expect(find.textContaining('LEFT   frames 0'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);

    await close(tester);
  });

  testWidgets('shows Bluetooth off on scan', (tester) async {
    await open(tester);
    adapter.availabilityState = BleAvailability.poweredOff;

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();

    expect(find.text('State: Bluetooth is off'), findsOneWidget);
    await close(tester);
  });

  testWidgets('shows permission denied on scan', (tester) async {
    await open(tester);
    adapter
      ..permissionsGranted = false
      ..grantOnRequest = false;

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();

    expect(find.text('State: Bluetooth permission denied'), findsOneWidget);
    await close(tester);
  });
}
