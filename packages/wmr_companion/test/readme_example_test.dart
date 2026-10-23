// Compiles and runs the README example against the fake bridge, so the
// documented lifecycle cannot rot. The only addition is the one line where
// the README says "use the streams": it waits for the first gamepad frame.
import 'dart:async';

import 'package:test/test.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';

Future<GamepadState> runExample(BleTransport transport) async {
  final wmr = WmrCompanion(
    ble:
        transport, // UniversalBleTransport, a native transport or FakeTransport
    config: WmrCompanionConfig(
      streamMode: StreamMode.batched, // FF14
      fusion: FusionConfig.madgwick(beta: 0.05),
    ),
  );

  await wmr.initialize();
  await wmr.startScan();
  await for (final devices in wmr.bridges) {
    WmrBridgeDevice? bridge;
    for (final device in devices) {
      if (device.name == 'WMR Bridge') {
        bridge = device;
        break;
      }
    }
    if (bridge == null) continue;
    await wmr.connect(bridge);
    break;
  }
  await wmr.setStreamMode(StreamMode.batched);

  final subs = [
    wmr.controllers.listen((WmrControllerUpdate update) {
      // update.hand, update.receivedAtUs, update.frame (FF11),
      // update.decoded (FF12/FF14), update.orientation, update.input,
      // update.stats
    }),
    wmr.gamepad.listen((GamepadState state) {
      // Buttons, sticks, triggers, optional tilt: ready to drive a game.
    }),
    wmr.link.listen((WmrLinkSnapshot snapshot) {
      // MTU, RSSI, rate, sequence gaps, tick loss.
    }),
  ];

  final first = await wmr.gamepad
      .firstWhere((state) => state.leftConnected && state.rightConnected)
      .timeout(const Duration(seconds: 2));

  for (final sub in subs) {
    await sub.cancel();
  }
  await wmr.dispose();
  return first;
}

void main() {
  test('README example compiles and reads a gamepad frame', () async {
    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    final bridge = FakeWmrBridge(transport)..start();
    addTearDown(() async {
      bridge.stop();
      await transport.dispose();
    });

    final state = await runExample(transport);

    expect(state.leftConnected, isTrue);
    expect(state.rightConnected, isTrue);
    expect(state.buttons, isA<Set<GamepadButton>>());
  });
}
