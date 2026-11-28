# CLAUDE.md

Flutter companion library and reference app for ESP32 (BTstack) WMR controllers. Current state, hardware results and roadmap: `docs/STATUS.md`. Plan, architecture and milestones: `docs/PLAN.md`. Library architecture: `docs/LIBRARY.md`. Read before starting work.

## Architecture rules
- The repo is structured as federated packages (`packages/wmr_core`, `packages/wmr_companion` facade, `packages/wmr_ble`, `packages/wmr_ws`, `packages/wmr_fusion`, `packages/wmr_companion_ui`, `packages/wmr_companion_hid_android`, `packages/wmr_tracking`, `packages/wmr_tracking_dispatch`, `packages/wmr_tracking_android_xr`, `packages/wmr_tracking_viture`, `packages/wmr_tracking_xreal`, `packages/wmr_tracking_unity`, `packages/WMRCompanionKit`, `apps/wmr_visionos_app`, `example/`). The app under `apps/wmr_companion_app` (`wmr_companion_app`) is the reference consumer driving its real connection through the facade or ControllerService.
- Layers: UI -> Riverpod state -> `WmrCompanion` facade (`packages/wmr_companion`) -> `ControllerService` (`packages/wmr_core`) -> (protocol parsers in `packages/wmr_core` + `BleTransport`).
- `BleTransport` is an abstract interface living in `packages/wmr_core`. Implementations: `UniversalBleTransport` in `packages/wmr_ble` (default on Android/iOS for BLE), `WmrWsTransport` in `packages/wmr_ws` (WebSocket transport for Linux/Pi Wi-Fi daemon; host-tested/loopback-only), `WmrWsDiscovery` for LAN discovery of Pi bridges, `CompositeBleTransport` in `packages/wmr_companion` (opt-in TCP-first with BLE GATT fallback), `FakeTransport` in `packages/wmr_companion/testing.dart` (tests/UI dev), and native CoreBluetooth via `packages/WMRCompanionKit` (iOS). `BleTransport` is GATT-shaped, but its name is settled for 0.1.0: the owner decided to keep it (it wraps third-party libraries). Keep it swappable.
- Protocol parser is pure Dart in `packages/wmr_core` (no Flutter, Riverpod, or plugin imports; verified by CI grep) and unit tested with golden byte arrays.
- Timestamp notifications with a monotonic `Stopwatch` at the transport boundary (`wmr_ble`).
- Never compare ESP32 timestamps with the phone clock; use inter-arrival deltas and sequence numbers. For FF12/FF14, the time step comes from `device_ticks` (100 ns), not from arrival time.
- Keep heavy work off the UI isolate or behind interfaces so it can move.
- `packages/wmr_tracking_unity` is a C#/Unity 6000.0 project (not Dart): one unified `WmrTrackingRelay` bridge that dispatches Kotlin `OnCommand` JSON to the VITURE or XREAL bridge. `Assets/WmrTrackingViture/Runtime` and `Assets/WmrTrackingXreal/Runtime` are byte-identical copies; the per-vendor projects `packages/wmr_tracking_{viture,xreal}/unity` are the source of truth. Edit there, then run `packages/wmr_tracking_unity/tool/sync_vendor_unity_runtime.sh`. Details: `packages/wmr_tracking_unity/README.md`.

## Protocol
- The firmware repo https://github.com/nightcinder/WMR_Bridge is the source of truth (`docs/PROTOCOL.md`, `docs/ANDROID.md`). It sends raw, fragmented 46-byte WMR HID frames with per-hand sequence numbers: no quaternion, no timestamp. The firmware also serves a decoded stream (FF12, notify only, 56-byte records, mutually exclusive with FF11); the app parses it and fuses on the phone. Batched FF12 (FF14) is the app's **default** stream and the app requests ATT MTU 517 on every connect (up to 9 records per batch). The echo characteristic FF15 answered 479/479 pings in a hardware run (round trip p50 40.8 ms, p95 72.8 ms, user-reported). Multi-bridge (several bridges at once, e.g. Left and Right ESP32s merged into shared per-hand pipelines) exists. FF16 (bridge firmware version string) is read once after connect and published as `WmrProtocolVersion` on `WmrLinkSnapshot` and `WmrCompanion.protocol` (#46). Do not invent UUIDs or layouts.
- Ask before changing the GATT protocol.

## Commands
- App (`apps/wmr_companion_app`; run these from that directory):
  - `flutter pub get` (once at the repo root: it is a pub workspace)
  - `dart format --output=none --set-exit-if-changed <dirs>` from the repo root (CI's exact dir list is in the `build-static` job; `apps/wmr_companion_app` is formatted only under `lib` and `test`)
  - `flutter analyze`
  - `flutter test`
  - `flutter run --flavor base -d <device>` (BLE needs a physical phone; emulators do not work)
  - `tool/build_flavor.sh base` (flavors: `base`, `unified`; only unified ships)
- Per-package:
  - `packages/wmr_core`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_companion`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_ble`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/wmr_ws`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_fusion`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_companion_ui`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/wmr_companion_hid_android`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/wmr_tracking`: `dart test` (also `dart pub get`, `dart analyze`)
  - `packages/wmr_tracking_dispatch`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/wmr_tracking_android_xr`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/wmr_tracking_viture`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/wmr_tracking_xreal`: `flutter test` (also `flutter pub get`, `flutter analyze`)
  - `packages/WMRCompanionKit`: `swift test`
  - `apps/wmr_visionos_app`: `swift build && swift test`  - `packages/wmr_tracking_unity`: `packages/wmr_tracking_unity/tool/test_dispatch.sh` (needs .NET 8 SDK; runs the vendor-copy `--check`, stub compiles, dispatch and loader-gate tests; no Unity install). Unity export itself (`-executeMethod ...WmrTrackingUnityExport.Export`) needs Unity 6000.0.27f1 and the vendor SDKs: owner-run only.
  - `packages/wmr_tracking`: also `dart run tool/xr_contract_harness.dart`, `dart run tool/gate7_clock_replay.dart --fixture tool/fixtures/gate7/stable_offset.json`, `dart run tool/gate8_fallback_quality.dart`
- Repo root, as CI runs them:
  - `./tool/fresh_app_check.sh`
  - `python3 -m unittest -v tool/test_release_notes.py tool/test_mobsf_scan.py`
  - from `apps/wmr_companion_app`: `python3 -m unittest -v tool/test_check_unified_apk.py tool/test_check_unity_export.py`, `tool/test_unity_export_install.sh`, `tool/test_flavor_wiring.sh`
  - Kotlin plugin tests: see the `android-flavors-kotlin` job in `.github/workflows/ci.yml`
  - Publish dry-run per published package: `dart pub publish --dry-run` (`flutter pub publish --dry-run` for Flutter packages)

- Example app:
  - `cd example && flutter pub get && flutter test && flutter build apk --debug`
- iOS config validation (macOS / CI):
  - `flutter build ios --config-only --no-codesign`
  - `cd example && flutter build ios --config-only --no-codesign`

## Done gate (before opening a PR)
- Run `dart format` check, `flutter analyze` (app) and the test suite of every package you touched; CI runs all of them plus `gitleaks` and `semgrep`. Docs-only changes skip the Flutter build jobs.
- Say which commands you ran and which you did not. Heavy jobs (full Gradle APK, iOS, Unity export) are CI or owner-run.
- PRs get an automated review (Arthur / Paperclip bot). It blocks on `error` findings; answer each with a fix commit.

## Gotchas (recurring review findings)
- Citing code in docs or run sheets (`file.dart:84-85`): re-check line numbers against the final head. Stale `file:line` refs and counts ("two intervals", "Gates 2, 7, 8") that disagree with the table beside them are the most common finding.
- A documented gate must measure exactly what the tests measure (e.g. dial end minus dial start, not dial start to first record). Match the interval definition in code.
- Timeline and timestamp state is per attempt: reset every field at the start of a new connect or dial episode, and do not stamp disconnect for a dial that never started. Use `link_timeline.episode_last_tcp_record_us` for the current outage, not the live top-level value.
- Tests that override timeouts or budgets (`tcpProbeBudget`, `bootDarkRoute`) must not back claims about production defaults.
- Per-candidate caps must not shrink a lone candidate's budget.
- Before installing a new debug APK on a device, uninstall `com.onyxlens.wmr_companion.debug` first (`adb install -r` keeps stale app data).

## Conventions
- Tests must be hardware-free (use `FakeTransport`).
- Small commits, one milestone per PR; squash merges.
- Nothing is described as verified on hardware unless the project owner reported the result; mark such results "user-reported".
- Windows host: do not spend effort on Windows-only test problems (CRLF fixtures); CI on Linux is the reference.
- Commit messages end with the Co-Authored-By and Claude-Session lines given by the session.
- Keep `docs/STATUS.md` current when a milestone, hardware result or open problem changes.
- Never commit secrets, keystores, `key.properties`, or `local.properties`.

## Licensing (VITURE SDK)
- Never commit, upload as a release asset, or publish as a CI artifact the VITURE SDK: no `libglasses.so` outside the built APK, no headers, no archive containing them. Only the APK may carry `libglasses.so` (`jniLibs/` is gitignored).
- No VITURE SDK benchmark numbers in published material without VITURE's written consent. Do not use "VITURE" in the app name. Rules and clause numbers: `docs/VITURE_SDK.md`.

## Don'ts
- Do not change the GATT protocol or UUIDs without asking.
- Do not import Flutter, Riverpod or plugins into `wmr_core`.
- Do not claim hardware verification the owner did not report.
- Do not edit the vendor Runtime copies under `packages/wmr_tracking_unity/unity/Assets/WmrTrackingViture|Xreal`.
