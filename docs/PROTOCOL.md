# BLE protocol: app-side notes

The wire format is defined in the firmware repo, not here:
[WMR_Bridge docs/PROTOCOL.md](https://github.com/nightcinder/WMR_Bridge/blob/main/docs/PROTOCOL.md),
[docs/ANDROID.md](https://github.com/nightcinder/WMR_Bridge/blob/main/docs/ANDROID.md),
`wmr_bridge.gatt`, `src/wmr_protocol.c`, `tests/test_protocol.c`.

This file records only what the app does with it.

## Mirrored firmware revision

`lib/protocol/` mirrors WMR_Bridge commit `62b5177` (2026-10-21). When the
firmware protocol changes, update `lib/protocol/`, the tests and this line
together.

| Firmware | App |
| --- | --- |
| `wmr_bridge.gatt` UUIDs, device name | `lib/protocol/gatt.dart` |
| FF11 16-byte status read | `BridgeStatus.parse` (`lib/protocol/bridge_status.dart`) |
| `wmr_proto_notification_capacity`, `wmr_proto_encode_fragment` | `notificationCapacity`, `encodeFragment`, `encodeFrame` |
| `wmr_reassembler_push` and its counters | `WmrReassembler.push` (`lib/protocol/wmr_fragment.dart`) |
| `tests/test_protocol.c` | `test/protocol/wmr_fragment_test.dart` (ported case by case) |
| `samples/controller_frames.txt` | `test/fixtures/controller_frames.txt` (copy) |

The encoder is in the app only so `FakeWmrBridge` and the tests can produce
the exact notifications the ESP32 sends.

## App-side decisions

- **Timestamps.** The stream carries no ESP32 time. Each notification is
  stamped by the transport with a monotonic clock (`BleNotification.receivedAtUs`);
  a reassembled frame carries the stamp of its last fragment.
- **Sequence accounting** (`ControllerService`), per hand, using modular
  `sequenceDelta`: delta > 1 adds `delta - 1` to `gaps`; delta <= 0 counts as
  `outOfOrder` (duplicate, reorder, or ESP32 reboot). The first frame after
  subscribing sets the baseline and is not counted as a gap.
- **Requested MTU** 247 (`wmrRequestedMtu`). The app must use the negotiated
  value it gets back.
- **Reconnects.** `ControllerService.start()` must run again after every
  reconnect (the bridge forgets subscription, MTU and priority).
- **Frame payload.** FF11 frames stay undecoded and are shown only as a raw
  debug view. Orientation will come from the planned decoded characteristic
  (proposed FF12, see `docs/PLAN.md`) once its layout is fixed in the firmware.
  Until then the 3D view runs on `SyntheticMotion`.

## universal_ble 3.1.2 coverage

Read from the 3.1.2 source in the pub cache, not from memory.

| Need | API | Notes |
| --- | --- | --- |
| MTU | `requestMtu(deviceId, mtu)` | Returns the value the stack reports afterwards; the transport records that, never the request. Android 13 and older: one request per connection; Android 14+: the stack drives the MTU, later requests are ignored. iOS/macOS: the app cannot request an MTU, the OS value comes back (and is only meaningful after service discovery, which the package does on demand). Windows/Linux: query only. Web: unsupported. |
| Connection priority | `requestConnectionPriority(.., highPerformance)` | Android only; throws `notSupported` elsewhere, so the transport skips the call when `BleCapabilities.supportsConnectionPriorityApi` is false and `priorityRequested` stays null. |
| RSSI | `readRssi` | Read on demand in `connectionInfo`. |
| Notifications | `subscribeNotifications`, `characteristicValueStream` | The value stream carries no timestamp; the transport stamps in its own listener. `onValueChange` has a platform timestamp, unused (not comparable across platforms, and the rule is to use our monotonic clock). |
| Permissions | `hasPermissions`, `requestPermissions` | Handled by the plugin: Android 12+ BLUETOOTH_SCAN/BLUETOOTH_CONNECT (and older location) are requested from the activity, based on what the manifest declares; iOS via CoreBluetooth authorization. `permission_handler` is not needed and not added. Needs an activity in the foreground; denial throws `UniversalBleException`. |
| Bluetooth state | `getBluetoothAvailabilityState`, `availabilityStream` | Maps to `bluetoothOff` / `permissionDenied` (unauthorized) / `bluetoothUnavailable`. |
| Connection interval | `onConnectionParametersChange` | Android API 26+ only, a global static callback fired when the stack reports an update. `connectionIntervalUs` is filled only after the first such callback and stays null on iOS and before any update. Not queryable on demand. |
| PHY | none | gap: `BleConnectionInfo.phy` stays null on every platform. |

## Real transport (`UniversalBleTransport`)

**Not tested on hardware.** It was written against the package source and
exercised only with a fake adapter (`test/ble/`). Nothing here has been seen
working with a phone or an ESP32, including the connection sequence, the
scan filter, permission prompts, reconnects and the interval callback.

- `BleAdapter` (`lib/ble/ble_adapter.dart`) is the thin interface over the
  package; `UniversalBleAdapter` is the only file that imports
  `universal_ble`.
- `connect()` runs: permissions, radio state, link, `requestMtu(247)` (record
  the result), high priority if supported, service discovery, check for
  FF10/FF11. `subscribe()` then enables notifications; it is queued behind
  the setup, so it cannot run before the MTU result. All steps go through one
  serial queue. A failed MTU or priority request is a warning in
  `BleLinkStatus.warnings`; missing FF10/FF11 or a failed link is an error.
- The sequence runs again on every `connect()`. After an unexpected drop the
  transport reports `connectionLost` and does nothing else; the UI offers
  Reconnect, which calls `ControllerService.start()` again. `start()` also
  resets the per-hand sequence baseline, since the ESP32 keeps counting
  while the phone is away.
- Scan matches the name `WMR Bridge` or service FF10 (the package ORs the
  filter conditions) and times out after 15 s with `scanTimeout` if nothing
  matched.
- The FF11 status read is `readBridgeStatus`, on demand only.
- Failure states exposed to the UI: `bluetoothOff`, `bluetoothUnavailable`,
  `permissionDenied`, `scanTimeout`, `connectFailed`, `serviceNotFound`,
  `connectionLost`.
- Open question: the package's connect has its own 60 s default timeout and
  the command queue a 10 s default for other steps; neither was tuned.
