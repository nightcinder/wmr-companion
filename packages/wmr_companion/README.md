# wmr_companion

Public facade for reading [WMR Bridge](https://github.com/nightcinder/WMR_Bridge)
controller input **in-process**. Android and iOS are both v1 targets.

This package is the umbrella API from `docs/LIBRARY.md`. It wraps
`packages/wmr_core` (protocol, fusion, gamepad mapping) and takes any
`BleTransport`; it has no Flutter, Riverpod or widget dependency, so a host app
can adapt the streams to whatever state layer it already uses. The reference
app in this repository is the first consumer.

Status: **0.2.2, landed**. All twelve packages — `wmr_core`, `wmr_companion`,
`wmr_ble`, `wmr_ws`, `wmr_fusion`, `wmr_tracking`, `wmr_tracking_dispatch`,
`wmr_tracking_android_xr`, `wmr_tracking_viture`, `wmr_tracking_xreal`,
`wmr_companion_ui` and `wmr_companion_hid_android` — are in the pub workspace at
0.2.2 and pass their export boundary checks; publishing to pub.dev is on hold per
the owner's decision. The facade works on the fake transport and is dogfooded by
the app's real connection path, including `WmrWsTransport` alongside
`UniversalBleTransport` and `FakeTransport`. Nothing here has been run on iOS
hardware.

The optional, publishable `wmr_tracking` package (covered by the release
dry-run) defines the `TrackingSource` seam and `SixDofFuser` behind `poses`.
The facade re-exports its types. Vendor adapters ship in their own packages
(`wmr_tracking_android_xr`, `wmr_tracking_viture`, `wmr_tracking_xreal`) and
are off by default; no headset has been tested; see
[`docs/TRACKING.md`](../../docs/TRACKING.md).

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
      // MTU, RSSI, rate, sequence gaps, tick loss, and snapshot.protocol
      // (FF16 firmware version plus the bridge's feature matrix).
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
| `initialize()` | Reset to idle. Adapter/permission checks live in the BLE package (`wmr_ble`). |
| `startScan()` / `stopScan()` | Scan and publish `bridges`, strongest RSSI first, de-duplicated by id. |
| `connect(WmrBridgeDevice)` | Connect and enable the configured stream. Also the reconnect call. |
| `setStreamMode(StreamMode)` | Switch FF11 raw, FF12 decoded, FF14 batched or none. |
| `disconnect()` | Close the link and return to idle. |
| `controllers` | FF11 frames or FF12/FF14 samples, one event per frame/sample. |
| `gamepad` | Mapped two-handed `GamepadState`, one event per decoded sample. |
| `poses` | Fused `ControllerPose` per decoded sample while a `TrackingSource` is attached; position is null without a head or hand anchor. |
| `attachTrackingSource(TrackingSource)` | Start and own a head/hand tracking source, align its clock to the BLE stream and enable `poses`. |
| `detachTrackingSource()` | Stop and dispose the attached source and disable `poses`. |
| `link` | `WmrLinkSnapshot`: state, MTU, RSSI, interval, mode, fault, protocol, counters. |
| `protocol` | The bridge's `WmrProtocolVersion` (FF16 firmware version and feature matrix) after the one-time read. |
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

## Bridge firmware and the FF16 version

Firmware `WMR_Bridge` #38 (`41771f8`) added a read-only FF16 characteristic:
a UTF-8 `PROJECT_VER` string with no terminator, at most 31 bytes. It is the
same value the build writes to `manifest.json` and `build-info.json`, so a host
can match a running bridge to a release without a serial console. A build made
directly with `idf.py` reports that project's `PROJECT_VER` (ESP-IDF's default
is `1`).

The controller service reads FF16 once after connect, after the transport's
MTU/priority setup, and the facade publishes the result on
`WmrLinkSnapshot.protocol`:

```dart
wmr.link.listen((WmrLinkSnapshot snapshot) {
  final protocol = snapshot.protocol; // null until the read returns
  final version = protocol?.firmwareVersion; // null on a pre-#38 bridge
  final batching = protocol?.features.batchedStream ?? false;
});
```

`WmrCompanion.protocol` returns the same value without waiting for the next
snapshot. The read is best-effort: it never appears on `failures`, and a value
that cannot be decoded is flagged (`firmwareVersionMalformed`) rather than
thrown. A discovery failure leaves `protocol` null; a failed FF16 read leaves
`firmwareVersion` null (the feature matrix is still published). The read is
fired after `connect` reports `ready`, so a slow read does not delay the
stream. `UniversalBleTransport` caches the GATT table from its connect
sequence, so the service's lookup does not run a second platform discovery on a
live link; a custom transport must do the same or expect one extra
`discoverServices` call after connect.

`WmrProtocolVersion.features` is a capability matrix taken from the bridge's
GATT table, not parsed from the version string. The string is free-form
(`build.py` uses a tag or `git describe`; a direct `idf.py` build reports `1`),
so the characteristics are the reliable signal:

| Feature | Characteristic | When the bridge offers it |
| --- | --- | --- |
| `rawStream` | FF11 | every known firmware |
| `decodedStream` | FF12 | every firmware with the decoded stream |
| `batchedStream` | FF14 | firmware with batching; also needs ATT MTU >= 61 |
| `configBlock` | FF13 | firmware with the config block (`WMR_Bridge` #17) |
| `echo` | FF15 | firmware with echo (`WMR_Bridge` #13) |
| `firmwareVersion` | FF16 | firmware with #38 (`41771f8`) and later |

A bridge with no FF16 is an older firmware and a normal status:
`protocol.firmwareVersion` is null and `features.firmwareVersion` is false. The
rest of the matrix still describes what that bridge can do. Unknown
characteristics are ignored, and callers must ignore records or fields their
app does not know instead of treating them as fatal.

None of this is a hardware claim: the firmware change is merged, and this client
is exercised against the fake bridge only.

## Platform notes

- **Android:** `BLUETOOTH_SCAN` (`neverForLocation`) and `BLUETOOTH_CONNECT`;
  legacy `ACCESS_FINE_LOCATION` with `maxSdkVersion=30`. Requesting MTU 517 and
  high connection priority after connect stays with the transport/BLE package;
  `BleTransport` has no MTU-request call yet, so the facade does not expose one.
- **iOS:** `NSBluetoothAlwaysUsageDescription` in the host's `Info.plist`.
  `bluetooth-central` background mode only if the host claims background
  operation. iOS chooses MTU and connection interval; the facade can report null
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
