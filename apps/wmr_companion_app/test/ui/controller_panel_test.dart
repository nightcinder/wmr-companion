import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_companion_app/ui/debug/controller_panel.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('shows both hands and connects one over FF17', (tester) async {
    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    FakeWmrBridge(transport, discoveryDuration: Duration.zero);
    await transport.connect(fakeBridgeDeviceId);
    addTearDown(transport.dispose);

    await tester.pumpWidget(
      _wrap(
        ControllerPanel(
          transport: transport,
          deviceId: fakeBridgeDeviceId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LEFT  not connected'), findsOneWidget);
    expect(find.text('RIGHT  not connected'), findsOneWidget);

    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('LEFT  connected - WMR'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('shows the stream-stutter warning while scanning', (
    tester,
  ) async {
    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    FakeWmrBridge(transport); // 1.5 s discovery, so the state is visible.
    await transport.connect(fakeBridgeDeviceId);
    addTearDown(transport.dispose);

    await tester.pumpWidget(
      _wrap(
        ControllerPanel(
          transport: transport,
          deviceId: fakeBridgeDeviceId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scan for controllers'));
    await tester.pump();
    expect(find.textContaining('Scanning (round 1)'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Scanning (round'), findsNothing);
  });

  testWidgets('an older bridge without FF17 says so', (tester) async {
    const oldBridge = FakeDevice(
      id: 'old-bridge',
      name: wmrBridgeDeviceName,
      services: [
        BleServiceInfo(
          uuid: wmrBridgeServiceUuid,
          characteristicUuids: [wmrBridgeStreamCharUuid],
        ),
      ],
    );
    final transport = FakeTransport(devices: const [oldBridge]);
    await transport.connect(oldBridge.id);
    addTearDown(transport.dispose);

    await tester.pumpWidget(
      _wrap(ControllerPanel(transport: transport, deviceId: oldBridge.id)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('does not expose FF17'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Scan for controllers'))
          .onPressed,
      isNull,
    );
  });
}
