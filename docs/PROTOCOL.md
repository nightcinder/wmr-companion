# BLE protocol: app-side notes

The wire format is defined in the firmware repo, not here:
[WMR_Bridge docs/PROTOCOL.md](https://github.com/nightcinder/WMR_Bridge/blob/main/docs/PROTOCOL.md),
[docs/ANDROID.md](https://github.com/nightcinder/WMR_Bridge/blob/main/docs/ANDROID.md),
`wmr_bridge.gatt`, `src/wmr_protocol.c`, `tests/test_protocol.c`.

This file records only what the app does with it.

## Mirrored firmware revision

`lib/protocol/` mirrors WMR_Bridge commit `62b5177` (2026-10-21). When the
firmware protocol changes, update `lib/protocol/`, the tests and this line
together. The FF12 parts (`decoded_record.dart`, the FF12 UUID) mirror the
`ff12-decoded-stream` branch at `8fcb6a1` (merged as `a0cba83`); see the FF12
section. The FF14 parts (`decoded_batch.dart`, the FF14 UUID and minimum MTU)
mirror `main` at `8f5921a`; see the FF14 section.

| Firmware | App |
| --- | --- |
| `wmr_bridge.gatt` UUIDs, device name | `lib/protocol/gatt.dart` |
| FF11 16-byte status read | `BridgeStatus.parse` (`lib/protocol/bridge_status.dart`) |
| `wmr_proto_notification_capacity`, `wmr_proto_encode_fragment` | `notificationCapacity`, `encodeFragment`, `encodeFrame` |
| `wmr_reassembler_push` and its counters | `WmrReassembler.push` (`lib/protocol/wmr_fragment.dart`) |
| `tests/test_protocol.c` | `test/protocol/wmr_fragment_test.dart` (ported case by case) |
| `wmr_batch_parse`, `wmr_batch_max_count` (`src/wmr_batch.c`) | `parseDecodedBatch`, `batchMaxCount` (`lib/protocol/decoded_batch.dart`) |
| `tests/test_batch.c` golden bytes and MTU table | `test/protocol/decoded_batch_test.dart` |
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
- **Frame payload.** FF11 frames stay undecoded and feed the Capture screen
  and the raw debug view. Orientation comes from FF12 (see "FF12 decoded
  stream" below); the fake bridge in raw mode still runs on `SyntheticMotion`.

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
itself and ignores `temperature_raw`, `trackpad`, `trigger` and `battery`
apart from parsing them. `stick` is normalized (see "Stick centre").

## FF12 in the app

**Not verified on hardware.** Everything here is built against the spec above
and exercised only with fakes (`FakeAdapter`, `FakeTransport`,
`FakeWmrBridge`).

### Stream mode and the CCC rule

- `ControllerService` has a `StreamMode` (`raw` = FF11, `decoded` = FF12,
  `batched` = FF14; see the FF14 section).
  `setMode` is a re-subscribe; `start()` repeats it after every reconnect.
- `UniversalBleTransport.subscribe` knows the two bridge streams are
  exclusive: it forgets the other one from the wanted set at once and, in its
  serial GATT queue, writes `0x0000` to the other CCC (if enabled) before it
  enables the new one. After a reconnect `_setup` enables only what is
  wanted, from scratch. `unsubscribe` writes `0x0000` on its own.
- Failures arrive as `BleStreamException` on the stream returned by
  `subscribe` and become `ModeFault`s on the service, shown as a red banner
  (connect screen and debug screen): `otherStreamActive` (ATT `0x80`),
  `disableFailed` (the previous stream could not be turned off, so the new
  one was not tried), `enableFailed`, `mtuTooSmall` (negotiated MTU below 59).
  A refused `0x80` keeps the link `ready`; other enable failures still set the
  link to `connectFailed` as before.
- ATT `0x80` is recognised by `parseAttError` from the platform message
  ("ATT error: 0x80", "status 128", a bare `0x80`). **How `universal_ble`
  words that error on Android, iOS, Windows has not been seen**; if the code
  is not recognised the failure is reported as `enableFailed` with the raw
  message, never dropped. (On Android 128 is also `GATT_NO_RESOURCES`.)
- The Capture screen needs FF11: the connect screen's Capture button switches
  to raw first and does not open Capture if the switch was refused.

### Timing

- `dt` for the filter is `TickTimer`'s `(ticks - previous) mod 2^32 * 100 ns`.
  Arrival time is never used.
- The spec's discontinuity rule is applied per hand: `|dt_ticks * 100 ns -
  delta(rx_time_us) * 1000 ns| > 100 ms`, or `rx_time_us` going backwards,
  re-baselines the hand and resets the filter's internal state while keeping
  its orientation.
- A `dt` above 100 ms skips that filter step (`largeDtSkips`) and restarts the
  gyro-bias window. A `dt` of a few periods (lost reports) is integrated with
  its real value.
- **Missing reports** use the **firmware's definition**, so the app's number
  and the bridge's `dev_missing` (LINKLOG / `link:` line, WMR_Bridge
  `docs/COUNTERS.md`) mean the same thing. Read from `src/wmr_devloss.c`,
  `docs/COUNTERS.md`, `docs/DECODING.md` and `tools/analyze_capture.py`
  (`device_loss`) on `main`: each delta between consecutive reports spans
  `round(delta / period)` periods, so that minus one are missing; `period` is
  the **median of the deltas not longer than 1.5x the 10th-percentile delta**
  (`sorted[n / 10]`), over a sliding window of the last 256 deltas, refreshed
  every 32 deltas. Nothing is counted until 16 deltas exist (they are then
  counted retroactively); a zero delta is ignored; a delta over 5 s is not
  counted as missing (`longGaps`). This replaces the earlier app rule (plain
  10th-percentile period, 32-delta warm-up), which sat at the low end of the
  jitter and so differed from the firmware's nominal period (the firmware's
  own write-up quotes 4.98 ms for the missing percentages). The reason for
  following the firmware: the two numbers can then be compared directly. The
  app resets its window on a timer discontinuity (the firmware resets on a
  Classic reconnect); that is the one deliberate difference. Same limit as
  the firmware: perfectly uniform loss looks like a slower controller. The
  count is shown next to the sequence-gap count, which is unchanged: sequence
  gaps only see reports lost after the ESP32 numbered them, the tick count
  also sees reports lost on the controller link. The nominal period in use is
  shown per hand on the debug screen. Like the rest of this section, the
  counter has not been compared against a live bridge.
- `tick/clock` (controller ticks at 100 ns over ESP32 `rx_time_us`) is shown as
  a check of the unverified 100 ns unit; about 1.0 if it is right.

### Gyro bias and filter

- Bias is the mean gyro over the first 1.0 s (sum of tick `dt`) that looks
  stationary: gyro std below 0.05 rad/s per axis, mean below 0.25 rad/s,
  accel-magnitude std below 0.25 m/s^2. Otherwise the window restarts. Until
  it completes the gyro is used uncorrected. The thresholds are guesses from
  the firmware's "about 0.016 rad/s" noise figure, not tuned.
- "Recalibrate gyro bias" restarts the search for the selected hand.
- Madgwick (default) or Mahony from `packages/wmr_fusion`; Mahony runs with
  `ki = 0` because the bias is estimated here.
- No magnetometer: **yaw drifts**. "Reset orientation" zeroes the heading of
  the fused filter (`resetYaw`).

### Stick centre

**Not verified on hardware.** `StickNormalizer` (`lib/domain/stick_centre.dart`,
one per hand inside `HandPipeline`) turns the raw `stick` i16 pair into -1..1.
A stick can rest off-centre; the only figure we have is one user-reported
measurement (RIGHT y about 0.148 of full scale), not a property established
for the hardware in general.

- **Learned centre.** With learning on, a sample is a rest candidate when the
  stick is within 0.25 of full scale of zero and the controller is not being
  used otherwise: no button bit set, trigger 0, trackpad 0, and bias-corrected
  gyro magnitude at most 0.3 rad/s (a guess). If the stick then stays within
  0.02 of where the candidate began for 1.0 s of tick time, the mean of that
  stretch becomes the centre. A step above 100 ms or a stream restart drops
  the candidate. The stick held still and slightly deflected inside the window
  for a second is therefore taken as rest; use "Re-centre stick" or switch
  learning off if that is wrong.
- **Output.** Centre subtracted, each half-axis rescaled so the end stop still
  reaches +-1, clamped, then a radial dead zone (default 0.05, debug settings
  slider 0 to 0.3) rescaled so the zone edge is 0 and full deflection is 1.
- **Debug UI.** The learned or set centre and the normalized output are shown
  per hand; "Re-centre stick" takes the current reading of the selected hand
  as centre; a switch turns learning off.

## FF14 batched stream in the app

**Not verified on hardware; the firmware side has not been run on hardware
either.** Spec: WMR_Bridge docs/PROTOCOL.md, "Batched decoded stream, FF14".
One notification is `version` = 2, `count`, then `count` unchanged FF12
version 1 records (oldest first, both hands mixed), length exactly
`2 + 56 x count`.

- **Parsing.** `parseDecodedBatch` checks the header like `wmr_batch_parse`
  (too short, version not 2, count 0, length not `2 + 56 x count`) and then
  parses each record with `parseDecodedRecord`. A rejected batch counts in
  `DecodedStats.batchErrors` and nothing from it is fused. A bad record inside
  a good batch counts as a record error (length / version / hand) and the
  other records of that batch are still used.
- **Same pipeline.** Each record goes through exactly the FF12 path: per-hand
  sequence gaps, tick timing, fusion. Every record of a batch carries the
  batch's phone arrival time; `dt` comes from `device_ticks` and the jitter
  diagnostics from `rx_time_us`, so batching does not change the time step.
  The phone-side `rate` is computed from arrival times and is lumpier on FF14.
- **Exclusion.** FF11, FF12 and FF14 share the one-stream rule: switching
  writes `0x0000` to whichever is enabled before enabling the new one, in all
  six orders (`test/ble/stream_mode_transport_test.dart`). ATT `0x80` is
  reported as for FF12.
- **MTU.** FF14 needs at least 61 (FF12 needs 59), so `mtuTooSmall` fires at
  59 and 60 on FF14 only. The app still requests MTU 247, which allows at
  most 4 records per batch; 9 needs MTU 517.
- **Stats.** `DecodedStats` adds `batches`, `batchRecords`, `batchMean`,
  `batchMax` and `batchErrors`; the debug panel shows them as
  `FF14 batches  mean  max  rejected` while FF14 is active.
- **Fake bridge.** `FakeWmrBridge` sends FF14 with the firmware's flush rule:
  a full batch for `attMtu` at once, otherwise when the oldest queued record
  has waited `batchHold` (default 15 ms, the bridge's default hold).

## Axis mapping

FF12 carries gyro and accel in the controller's raw sensor axes:
`src/wmr_decode.c` applies no remapping, and the firmware docs say the axis
directions and signs of those axes are unverified. The 3D view is X right, Y
up, Z toward the viewer.

**Default** (`AxisMapping.defaultMapping`, `lib/domain/axis_mapping.dart`):

| View axis | Sensor axis |
| --- | --- |
| X | - sensor Y |
| Y | + sensor X |
| Z | + sensor Z |

Evidence: raw-frame captures analysed with `analyze_capture.py`, as reported
for this task. That analysis decodes the same words the firmware puts in FF12,
so the same mapping is used here; this was not re-derived, and the captures
themselves are not in this repo. The sign of the **vertical axis** (view Y =
+ sensor X) is the one the twist test left unverified; the gravity check (a
stationary controller held upright reads + 1 g on view Y) is the other thing
that would settle it. It is a proper rotation (determinant + 1).

Toggles (debug settings panel, applied from the next sample, no rebuild):

- **Flip view axis X/Y/Z**: negates that view axis for both gyro and accel.
  One or three flips make the frame left-handed, so gyro and accel then
  contradict each other; use it when an axis is wrong in both.
- **Flip rotation sense (gyro only) X/Y/Z**: negates that axis for the gyro
  only; use it when only the direction of a rotation is backwards.
- "Reset to default table".

The filter works in a z-up frame; `viewToFilter` maps view (X, Y, Z) to
(X, - Z, Y) and `filterToViewOrientation` conjugates the result back.

## Open questions

1. **Axis directions and signs** of the FF12 sensor axes, and the vertical
   sign in particular: unverified (see above and the firmware's DECODING.md).
2. **Tick unit** (100 ns) is from Monado's code only; `tick/clock` on the
   debug screen is the first thing to read once hardware is available.
3. **Does `device_ticks` restart when a controller reconnects?** Unknown. The
   app uses the spec's `rx_time_us` comparison to catch it; whether 100 ms is
   the right tolerance on a link that loses half the reports is untested.
4. **Gyro scale** (`1e-5` rad/s per count) is unconfirmed in a real rotation.
5. **How `universal_ble` reports ATT `0x80`** (see above).
6. **The `CALIBRATED` flag.** Always 0 in version 1. If a later version sets
   it the values may be in a different frame; the app only counts such
   records (`calibratedFlagged`) and still applies the axis table, which would
   be wrong then.
7. **Bandwidth.** Both hands at about 360 notifications/s on one connection is
   a firmware bench item; the app will show whatever arrives (`rate`).
8. **Period regularity** for the missing-report count (see "Timing").
9. The task brief called the firmware PR unmerged; PR 5 was merged into
   WMR_Bridge `main` while this was written (`a0cba83`). The spec text did not
   change, and it still says nothing has run on hardware.

## FF15 echo in the app

**Not verified on hardware; the firmware side has not been run on hardware
either.** Spec: WMR_Bridge docs/PROTOCOL.md, "Echo, FF15" (merged in #13).
Code: `lib/protocol/echo.dart` (pure Dart, golden bytes from the spec),
`lib/services/echo_client.dart`.

- **Request** is 4 bytes (`version` 1, reserved, `ping_id` u16), written
  *without response*; the **answer** is a 20-byte notification with the
  ping id, the ESP32 `rx_time_us` (same clock as FF12), `turnaround_us` and
  `queue_depth`. An answer of another length or version is dropped and
  counted.
- **Independent of the stream rule.** Enabling FF15 never conflicts with FF11,
  FF12 or FF14, so `EchoClient` subscribes on its own and never touches
  `ControllerService`'s subscription. The transport's exclusion handling only
  covers the three streams.
- **Detection.** The client looks for FF15 in service discovery before it
  subscribes, so an older bridge never gets a CCC write for a characteristic
  it does not have (a failed enable would mark the link failed).
- **One ping at a time**, as the firmware allows (a second is `busy`). No
  answer within 1 s is a timeout. A late answer is counted as stale.
- **Times.** `t1` is stamped just before the write is handed to the transport
  (GATT operations are serialized there, so any wait behind them counts) and
  `t4` is the transport's own stamp of the notification. `rtt = (t4 - t1) -
  turnaround_us`. The clock offset formula is computed per ping and only
  exported, never applied.
- **Fake bridge.** `FakeWmrBridge` answers valid pings while FF15 is
  subscribed (`echoDelay`, `echoTurnaround`, `echoEnabled` to ignore them).

