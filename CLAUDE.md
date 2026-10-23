# CLAUDE.md

Flutter companion library and reference app for ESP32 (BTstack) WMR controllers. Current state, hardware results and roadmap: `docs/STATUS.md`. Plan and architecture: `docs/PLAN.md`. Library architecture: `docs/LIBRARY.md`. Milestone plan: `/PAP/issues/ONY-50#document-plan`. Read before starting work.

## Architecture rules
- The repo is structured as federated packages (`packages/wmr_core`, `packages/wmr_companion` facade, `packages/wmr_ble`, `packages/wmr_fusion`, `packages/wmr_companion_ui`, `packages/WMRCompanionKit`, `example/`). The root app (`wmr_companion_app`) is the reference consumer driving its real connection through the facade.
- Layers: UI -> Riverpod state -> `WmrCompanion` facade (`packages/wmr_companion`) -> `ControllerService` (`packages/wmr_core`) -> (protocol parsers in `packages/wmr_core` + `BleTransport`).
- `BleTransport` is an abstract interface living in `packages/wmr_core`. Implementations: `UniversalBleTransport` in `packages/wmr_ble` (default on Android/iOS), `FakeTransport` in `packages/wmr_companion/testing.dart` (tests/UI dev), and native CoreBluetooth via `packages/WMRCompanionKit` (iOS). Keep it swappable.
- Protocol parser is pure Dart in `packages/wmr_core` (no Flutter, Riverpod, or plugin imports; verified by CI grep) and unit tested with golden byte arrays.
- Timestamp notifications with a monotonic `Stopwatch` at the transport boundary (`wmr_ble`).
- Never compare ESP32 timestamps with the phone clock; use inter-arrival deltas and sequence numbers. For FF12/FF14, the time step comes from `device_ticks` (100 ns), not from arrival time.
- Keep heavy work off the UI isolate or behind interfaces so it can move.

## Protocol
- The firmware repo https://github.com/nightcinder/WMR_Bridge is the source of truth (`docs/PROTOCOL.md`, `docs/ANDROID.md`). It sends raw, fragmented 46-byte WMR HID frames with per-hand sequence numbers: no quaternion, no timestamp. The firmware also serves a decoded stream (FF12, notify only, 56-byte records, mutually exclusive with FF11); the app parses it and fuses on the phone. Batched FF12 (FF14) is the app's **default** stream and the app requests ATT MTU 517 on every connect (up to 9 records per batch). The echo characteristic FF15 answered 479/479 pings in a hardware run (round trip p50 40.8 ms, p95 72.8 ms, user-reported). Multi-bridge (several bridges at once, e.g. Left and Right ESP32s merged into shared per-hand pipelines) exists. FF16 (bridge firmware version string) exists on firmware `main` and the app does not read it yet. Do not invent UUIDs or layouts.
- Ask before changing the GATT protocol.

## Commands
- Root app:
  - `flutter pub get`
  - `dart format --set-exit-if-changed .`
  - `flutter analyze`
  - `flutter test`
  - `flutter run -d <device>` (BLE needs a physical phone; emulators do not work)
  - `flutter build apk --debug`
- Per-package:
  - `packages/wmr_core`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_companion`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_ble`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/wmr_fusion`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_companion_ui`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/WMRCompanionKit`: `swift test`
- Example app:
  - `cd example && flutter pub get && flutter test && flutter build apk --debug`
- iOS config validation (macOS / CI):
  - `flutter build ios --config-only --no-codesign`
  - `cd example && flutter build ios --config-only --no-codesign`

## Conventions
- Tests must be hardware-free (use `FakeTransport`).
- Small commits, one milestone per PR; squash merges.
- Nothing is described as verified on hardware unless the project owner reported the result; mark such results "user-reported".
- Windows host: do not spend effort on Windows-only test problems (CRLF fixtures); CI on Linux is the reference.
- Commit messages end with the Co-Authored-By and Claude-Session lines given by the session.
- Keep `docs/STATUS.md` current when a milestone, hardware result or open problem changes.
- Never commit secrets, keystores, `key.properties`, or `local.properties`.
