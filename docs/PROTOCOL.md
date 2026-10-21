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

| Need | API | Notes |
| --- | --- | --- |
| MTU | `requestMtu` | returns the negotiated value |
| Connection priority | `requestConnectionPriority` | Android only |
| RSSI | `readRssi` | |
| Notifications | `subscribeNotifications`, `characteristicValueStream` | |
| PHY | none | gap: `BleConnectionInfo.phy` stays null |
| Connection interval | none | gap: `BleConnectionInfo.connectionIntervalUs` stays null |
