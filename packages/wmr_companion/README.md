# wmr_companion

Public facade for reading [WMR Bridge](https://github.com/nightcinder/wmr-companion)
controller input **in-process**. Android and iOS are both v1 targets.

This package is the umbrella API from `docs/LIBRARY.md`. It wraps
`packages/wmr_core` (protocol, fusion, gamepad mapping) and takes any
`BleTransport`; it has no Flutter, Riverpod or widget dependency, so a host app
can adapt the streams to whatever state layer it already uses. The reference
app in this repository is the first consumer.

Status: **phase 2**. The facade works on the fake transport and is dogfooded by
the app's real connection path. The BLE package (`wmr_ble`), UI kit, Android HID
add-on and publishing are later phases. Nothing here has been run on iOS
hardware.

## Why in-process input

iOS gives third-party apps no public virtual-gamepad or Bluetooth HID API. The
library therefore does not try to make the phone a system gamepad: the host app
links the pipeline and consumes `GamepadState`/`WmrControllerUpdate` directly.
Android keeps the existing Bluetooth HID output as an optional add-on package
for apps that want system-wide output.

## Use

Add it by path while the packages are unpublished:

```yaml
dependencies:
  wmr_companion:
    path: packages/wmr_companion
```

Then:

```dart
import 'package:wmr_companion/wmr_companion.dart';

Future<void> run(BleTransport transport) async {
  final wmr = WmrCompanion(
    ble: transport, // UniversalBleTransport, a native transport or FakeTransport
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

  // ... use the streams ...

  for (final sub in subs) {
    await sub.cancel();
  }
  await wmr.dispose();
}
```

`packages/wmr_companion/test/readme_example_test.dart` runs this example against
the fake bridge, so the snippet cannot rot.

## API

One class, one config, a handful of models.

| Member | Meaning |
| --- | --- |
| `initialize()` | Reset to idle. Adapter/permission checks arrive with `wmr_ble` (phase 3). |
| `startScan()` / `stopScan()` | Scan and publish `bridges`, strongest RSSI first, de-duplicated by id. |
| `connect(WmrBridgeDevice)` | Connect and enable the configured stream. Also the reconnect call. |
| `setStreamMode(StreamMode)` | Switch FF11 raw, FF12 decoded, FF14 batched or none. |
| `disconnect()` | Close the link and return to idle. |
| `controllers` | FF11 frames or FF12/FF14 samples, one event per frame/sample. |
| `gamepad` | Mapped two-handed `GamepadState`, one event per decoded sample. |
| `link` | `WmrLinkSnapshot`: state, MTU, RSSI, interval, mode, fault, counters. |
| `failures` | Typed non-fatal errors (scan failures, stream faults). |
| `setGamepadConfig` / `setAxisMapping` / `setFusion` / `setStickConfig` | Live reconfiguration. |
| `setStickCentre` / `clearStickCentre` / `recentreStick` | Stick rest centre, before or after connecting. |
| `setFf13Calibration` | Per-hand FF13 calibration, stored across reconnects. |
| `recalibrate` / `resetYaw` | Gyro bias and yaw, per hand. |
| `dispose()` | Close the BLE link and release the session, subscriptions and timers. The transport is the caller's. |

State machine: `idle → scanning → connecting → ready`, with `reconnecting`
after an unexpected drop (one retry when `autoReconnect` is on) and `failed`
when the link or the scan cannot be established. `reconnecting` is a state,
not an exception.

Errors are typed: `WmrConnectionException`, `WmrStreamModeException` (with a
`WmrStreamModeFaultKind`), `WmrTransportException`, `WmrConfigException`. Raw
platform exceptions never leave the facade; they are attached as `cause`.
`connect` throws `WmrStreamModeException` after the link is up if the stream did
not enable; the state is still `ready`, and the fault is on `link`, so the host
can show the banner and retry.

Two important rules:

- **Timestamps come from the transport.** `WmrControllerUpdate.receivedAtUs` is
  the monotonic clock at the transport boundary, and FF12/FF14 `dt` still comes
  from device ticks, never the phone clock.
- **No globals.** Two `WmrCompanion` instances in one process are independent.
  There is no singleton and no static mutable state.

## Platform notes

- **Android:** `BLUETOOTH_SCAN` (`neverForLocation`) and `BLUETOOTH_CONNECT`;
  legacy `ACCESS_FINE_LOCATION` with `maxSdkVersion=30`. Requesting MTU 517 and
  high connection priority after connect stays with the transport/BLE package;
  `BleTransport` has no MTU-request call yet, so the facade does not expose one.
- **iOS:** `NSBluetoothAlwaysUsageDescription` in the host's `Info.plist`.
  `bluetooth-central` background mode only if the host claims background
  operation. iOS chooses MTU and connection interval; the facade may report null
  for either.
- **Desktop/web:** out of scope for v1.

## What this package does not do

- It is not an iOS virtual gamepad and cannot make one appear.
- It does not promise iOS background operation, MTU or connection interval.
- It does not fix upstream controller-to-ESP32 report loss; it exposes the
  counters (`WmrHandStats`, `WmrLinkSnapshot.stats`) needed to see it.
- It does not include firmware. The bridge firmware is a separate,
  BTstack-derived project with its own licence.

## Licence

MIT for this package and the reference app. The Monado XOR key table is fetched,
never committed; the host supplies key bytes and the BSL-1.0 notice stays with
the host.

## Tests

```sh
dart pub get
dart analyze
dart test
```

The facade tests use `package:wmr_companion/testing.dart`, which re-exports
`FakeTransport` and `FakeWmrBridge` from `wmr_core`, so the whole lifecycle is
covered without a phone.
