# CLAUDE.md

Flutter companion app for ESP32 (BTstack) WMR controllers. Full plan: `docs/PLAN.md`. Read it before starting work.

## Architecture rules
- Layers: UI -> Riverpod state -> ControllerService -> (protocol parser + `BleTransport`).
- `BleTransport` is an abstract interface. Implementations: `UniversalBleTransport` (default), `FakeTransport` (tests/UI dev). Keep it swappable for a native transport later.
- Protocol parser is pure Dart (no Flutter imports) and unit tested with golden byte arrays.
- Timestamp notifications with a monotonic `Stopwatch` at the transport boundary.
- Never compare ESP32 timestamps with the phone clock; use inter-arrival deltas and sequence numbers.
- Keep heavy work off the UI isolate or behind interfaces so it can move.

## Protocol
- The ESP32 firmware is the source of truth. Do not invent UUIDs or packet layouts; read the firmware repo and mirror it in `docs/PROTOCOL.md` and `lib/protocol/`.
- Ask before changing the GATT protocol.

## Commands
- `flutter pub get`
- `flutter analyze`
- `flutter test`
- `flutter run -d <device>` (BLE needs a physical phone; emulators do not work)
- `flutter build apk --debug`

## Conventions
- Tests must be hardware-free (use `FakeTransport`).
- Small commits, one milestone per PR.
- Never commit secrets, keystores, `key.properties`, or `local.properties`.
