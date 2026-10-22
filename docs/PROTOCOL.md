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

## FF12 decoded stream

**Firmware status: not verified on hardware.** Read (read-only) from WMR_Bridge
PR 5, branch `ff12-decoded-stream`, head `8fcb6a1`: `docs/PROTOCOL.md`,
`docs/DECODING.md`, `src/wmr_decoded.{h,c}`, `src/wmr_decode.c`,
`src/wmr_stream_mode.h`, `tests/test_protocol.c`. While this app was being
written the PR was merged into WMR_Bridge `main` (merge commit `a0cba83`);
the spec text on `main` matches. The firmware's own text still says it is
host-tested and built but never run on hardware, and the app side has never
seen a real FF12 notification either. Everything below is the spec as
written, not a measurement. If the firmware changes, update
`lib/protocol/decoded_record.dart`, its test and this section together.

| Item | UUID | Properties |
| --- | --- | --- |
| Characteristic | `0000FF12-0000-1000-8000-00805F9B34FB` | notify only, in service FF10; no read value |

### Record (version 1)

One notification is one complete sample, exactly **56 bytes**, no
fragmentation. Little-endian; floats are IEEE 754 binary32.

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | u8 | `version` | `1`; ignore records with another version |
| 1 | u8 | `hand` | 0 LEFT, 1 RIGHT |
| 2 | u8 | `flags` | bit0 `CALIBRATED`, always 0 in version 1 |
| 3 | u8 | `buttons` | bit0 stick click, 1 home, 2 menu, 3 squeeze, 4 trackpad click, 5 BT pairing, 6 trackpad touch |
| 4 | u32 | `sequence` | same per-hand number as the raw FF11 frame it came from |
| 8 | u64 | `rx_time_us` | ESP32 `esp_timer_get_time()` at receipt; diagnostics only |
| 16 | u32 | `device_ticks` | controller timer, 100 ns/tick, wraps at 2^32; the sensor clock |
| 20 | 3 x f32 | `gyro` | rad/s, uncalibrated, raw sensor axes |
| 32 | 3 x f32 | `accel` | m/s^2 (about 10.0-10.1 at rest, not 9.81), uncalibrated, raw sensor axes |
| 44 | i16 | `temperature_raw` | scale not established |
| 46 | 2 x i16 | `stick` x, y | -32767..32767 |
| 50 | 2 x i16 | `trackpad` x, y | -32767..32767, 0 when untouched |
| 54 | u8 | `trigger` | 0..255 |
| 55 | u8 | `battery` | raw, scale not established |

Golden bytes: `decoded_golden` in the firmware's `tests/test_protocol.c`; the
same array is in `test/protocol/decoded_record_test.dart`, so firmware and app
are checked against identical bytes. Parser: `parseDecodedRecord`. It rejects,
like `wmr_decoded_unpack`, any length other than 56, a version other than 1 and
a hand above 1.

### Subscription

- FF11 and FF12 are **mutually exclusive**. While one CCC is enabled, a write
  that would enable the other fails with ATT application error `0x80`. To
  switch, write `0x0000` to the active CCC first, then enable the other.
- CCC state is per connection and resets on disconnect, so after every
  reconnect the app enables the wanted stream from scratch.
- Sequence numbers are shared across the two streams; a switch shows up as a
  gap (frames received while unsubscribed), not a reset.
- **Minimum ATT MTU 59.** Below it nothing is sent on FF12 and each report is
  discarded (`mtu_skip`). The app requests 247 and shows a fault when the
  negotiated MTU is below 59.

### Timing

- `dt` comes from `device_ticks`: `(ticks - prev) mod 2^32` ticks of 100 ns,
  valid while consecutive samples of one hand are less than 429.5 s apart.
  Ticks keep counting through lost reports, so a sequence gap is not a
  discontinuity and a larger `dt` is the true elapsed time.
- The 100 ns unit is from Monado's code only, **not measured**.
- The two hands have unrelated tick origins; never subtract across hands.
- Discontinuity rule from the spec: compare `dt_ticks * 100 ns` with
  `delta(rx_time_us) * 1000 ns`; if they differ by more than about 100 ms,
  reset the filter for that hand (it is not known whether the timer restarts
  when a controller reconnects).

### Axes and units

`src/wmr_decode.c` applies no axis remapping: gyro and accel are the three
signed 24-bit words in report order, scaled (gyro `* 1e-5` rad/s, accel `/
49000`, Monado's factors), so the FF12 axes are the same sensor axes that
`tools/analyze_capture.py` reports from raw frames. Directions and signs of
those axes are **unverified** in the firmware's own docs
(`DECODING.md`, "Unknown"). Gyro scale in a real rotation is unconfirmed too.

### Not in this app yet

FF13 (controller config block: mix matrix, bias, pose) is a design only in the
firmware docs. The app uses the uncalibrated values, estimates the gyro bias
itself and ignores `temperature_raw`, `stick`, `trackpad`, `trigger` and
`battery` apart from parsing them.
