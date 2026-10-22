# CLAUDE.md

Flutter companion app for ESP32 (BTstack) WMR controllers. Current state, hardware results and roadmap: `docs/STATUS.md`. Plan and architecture: `docs/PLAN.md`. Read both before starting work.

## Architecture rules
- Layers: UI -> Riverpod state -> ControllerService -> (protocol parser + `BleTransport`).
- `BleTransport` is an abstract interface. Implementations: `UniversalBleTransport` (default), `FakeTransport` (tests/UI dev). Keep it swappable for a native transport later.
- Protocol parser is pure Dart (no Flutter imports) and unit tested with golden byte arrays.
- Timestamp notifications with a monotonic `Stopwatch` at the transport boundary.
- Never compare ESP32 timestamps with the phone clock; use inter-arrival deltas and sequence numbers. For FF12, the time step comes from `device_ticks` (100 ns), not from arrival time.
- Keep heavy work off the UI isolate or behind interfaces so it can move.

## Protocol
- The firmware repo https://github.com/nightcinder/WMR_Bridge is the source of truth (docs/PROTOCOL.md, docs/ANDROID.md). It sends raw, fragmented 46-byte WMR HID frames with per-hand sequence numbers: no quaternion, no timestamp. The firmware also serves a decoded stream (FF12, notify only, 56-byte records, mutually exclusive with FF11); the app parses it and fuses on the phone. Batched FF12 (FF14) and the echo characteristic FF15 (round trip) are specified there and merged; neither firmware part has been run on hardware. Do not invent UUIDs or layouts.
- Ask before changing the GATT protocol.

## Commands
- `flutter pub get`
- `dart format --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`
- `flutter run -d <device>` (BLE needs a physical phone; emulators do not work)
- `flutter build apk --debug`

## Conventions
- Tests must be hardware-free (use `FakeTransport`).
- Small commits, one milestone per PR; squash merges.
- Nothing is described as verified on hardware unless the project owner reported the result; mark such results "user-reported".
- Windows host: do not spend effort on Windows-only test problems (CRLF fixtures); CI on Linux is the reference.
- Commit messages end with the Co-Authored-By and Claude-Session lines given by the session.
- Keep `docs/STATUS.md` current when a milestone, hardware result or open problem changes.
- Never commit secrets, keystores, `key.properties`, or `local.properties`.
