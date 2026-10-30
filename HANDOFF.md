# Handoff for a new orchestrator

Written 2026-10-22 by the outgoing "director" session; updated 2026-10-23 by General Helmuth von Moltke for ONY-55, 2026-10-24 for ONY-135, and 2026-10-27 for the 0.2.1 unified APK release. Read `docs/STATUS.md` first (current state and every hardware result), then this file. Where the two differ, STATUS is newer than this page's table of results.

Everything the project owner (Nick) has not reported is **not verified on hardware**. Results below are labelled "user-reported" when Nick pasted or told us the figure.

## 1. What the project is

Windows Mixed Reality motion controllers (LEFT, RIGHT) -> ESP32 running BTstack (Classic Bluetooth HID host) -> BLE GATT -> Android / iOS phone running a Flutter library and reference app. Goal: debug-mode 3DoF tracking of both controllers, then gamepad-style 3DoF input. **Android and iOS are both in scope for v1** (the owner settled iOS 18 as the floor, `docs/LIBRARY.md` §13). Longer-term goal (Nick, 2026-10-22): 6DoF by fusing the controller IMU with a headset's pose or cameras (URXR1, Xreal Aura, Xreal One Pro+Eye, Viture Luma Ultra were researched; none clearly exposes IR-capable tracking frames to apps, so the fallback is fusing the headset pose with the controller IMU). That goal needs the raw, timestamped IMU stream (FF12/FF14) on the camera device, so loss and latency come first.

The repository is no longer one monolithic Flutter app. It is a federated package tree with the root Flutter app (`wmr_companion_app`) acting as the reference consumer driving its real connection through the `WmrCompanion` facade:

- `packages/wmr_core`: Pure Dart protocol parsers (FF11/FF12/FF13/FF14/FF15), domain logic (timing, gyro bias, axis mapping, stick centres, gamepad mapping), `BleTransport` interface, `ControllerService`, and loss/latency statistics. No Flutter, Riverpod, or plugin imports (enforced by CI).
- `packages/wmr_companion`: Umbrella public facade (`WmrCompanion`), configuration, data models, typed exceptions, lifecycle, and broadcast stream subscriptions (`controllers`, `gamepad`, `link`). Host apps depend on this package.
- `packages/wmr_ble`: Flutter plugin implementing `UniversalBleTransport` via `universal_ble`, connection lifecycle hooks, and adapter status.
- `packages/wmr_ws`: Pure Dart WebSocket transport (`WmrWsTransport`) for the Linux/Raspberry Pi Wi-Fi bridge daemon behind `BleTransport` seam (host-tested/loopback-only).
- `packages/wmr_fusion`: Pure Dart 3DoF orientation filters (Madgwick, Mahony).
- `packages/wmr_tracking` (ONY-202, publishable): pure-Dart `TrackingSource` seam, normalised head/hand `TrackingFrame`, `SourceClockAligner`, 6DoF `SixDofFuser` with a shared One Euro hand-anchor filter, vendor capability profiles, Unity-to-OpenXR coordinate conversion and a JSON relay codec. `packages/wmr_tracking_android_xr` is the optional default-off Android XR Kotlin adapter (ONY-212), `packages/wmr_tracking_viture` is the optional default-off VITURE Pro Neckband Unity UaaL relay adapter (ONY-213) and `packages/wmr_tracking_xreal` is the optional default-off XREAL Air 2 Ultra Unity UaaL relay adapter (ONY-214); all three compile and pass host tests without having run on hardware. `packages/wmr_tracking_dispatch` (ONY-274) adds pre-Unity vendor detection, the Dart `TrackingSourceSelector` and one process-wide `SharedUnityRuntime` that both Unity plugins claim and reuse; `packages/wmr_tracking_unity` holds the one Unity project and relay used by the `unified` app flavor. See [docs/TRACKING.md](docs/TRACKING.md) and [docs/GLASSES_DETECTION.md](docs/GLASSES_DETECTION.md).
- `packages/wmr_companion_ui`: Reusable Flutter UI widgets (`OrientationView`, `LinkStatusView`, `HandStatsView`) extracted from the reference app's debug screen (merged in PR #45).
- `packages/wmr_companion_hid_android`: Optional Android Bluetooth HID gamepad output plugin (`BluetoothHidDevice`, merged in PR #48).
- `packages/WMRCompanionKit`: Native Swift framework targeting iOS 18+, macOS 12+, visionOS 1+ (CoreBluetooth transport, FF11–FF15 parsers, fusion, dual-bridge coordination) from ONY-38 (PR #37).
- `example/`: Minimal Flutter host demonstrating in-process controller consumption (~20 lines to gamepad state).
- App (`apps/wmr_companion_app`): The full reference consumer app (Connect with BLE and Wi-Fi host:port, Debug, Capture, Latency, Gamepad screens) driving its real connection through the `WmrCompanion` facade or ControllerService.

| Repo | What | Notes |
|---|---|---|
| `nightcinder/WMR_Bridge` | Firmware (C, built inside the BTstack ESP32 port) & Linux/Pi daemon (`pi/`) | Source of truth for the wire protocol (`docs/PROTOCOL.md`). BTstack-derived, non-commercial license. |
| `nightcinder/wmr-companion` | Federated Flutter library and reference app, MIT, public | Packages (`wmr_core`, `wmr_companion`, `wmr_ble`, `wmr_ws`, `wmr_fusion`, `wmr_tracking`, `wmr_tracking_android_xr`, `wmr_tracking_viture`, `wmr_tracking_xreal`, `wmr_companion_ui`, `wmr_companion_hid_android`, `WMRCompanionKit`) + `example/` + root reference app. |

GATT service FF10 on the bridge:
- FF11: raw fragmented HID frames (46 bytes)
- FF12: decoded 56-byte records (notify only)
- FF14: batches of FF12 records (`version` 2, up to 9 per notification at MTU 517); **app default stream**
- FF13: controller config blob (read in windows, CRC-32)
- FF15: echo characteristic for round-trip latency measurement (479/479 pings answered on hardware, user-reported)
- FF16: bridge firmware version string (exists on firmware `main` via PR #38; app/library support landed in PR #46, `WmrProtocolVersion`)

FF11/FF12/FF14 are mutually exclusive (a second enable fails with ATT error 0x80; write 0x0000 to the active one first). FF13, FF15, and FF16 are independent. Multi-bridge support (connecting multiple ESP32 bridges concurrently and merging notification streams into shared per-hand pipelines) is implemented in `ControllerService` (PR #34). App layers: UI -> Riverpod -> `WmrCompanion` facade -> `ControllerService` -> (parser + `BleTransport`). `BleTransport` is an abstract interface in `wmr_core`, implemented by `UniversalBleTransport` in `wmr_ble`, `WmrWsTransport` in `wmr_ws`, `FakeTransport` in `wmr_companion/testing.dart`, and native transport via `WMRCompanionKit`. The name is settled for `0.1.0`: the owner decided on ONY-146 to keep `BleTransport` as-is (GATT-shaped, but it wraps third-party libraries); the name is unchanged in `0.2.1`. Wi-Fi bridge streaming is host-tested / loopback-only until physical Pi sitting P1–P10.

## 2. Rules (from the project owner; keep them)

1. **Never state something as verified on hardware unless Nick reported it**; label such results "user-reported". Tests, CI and builds are not hardware results. If you or an agent made a wrong claim, correct it on the issue and in the docs.
2. **Check, don't assume.** Before saying something is merged, running, flashed or pushed, look (GitHub, logs, git). Before comparing hardware runs, check they are comparable (same position, MTU, connection interval, uptime; cumulative counters from long sessions are not comparable with fresh ones; use `last5s`).
3. **Approvals.** Merging PRs, deleting branches and other destructive git actions need Nick's explicit yes in the conversation. Ask once, in one line, then do both. A refused permission is not worked around. Branch deletion is refused by the permission layer in project threads; Nick deletes branches himself on GitHub.
4. Small PRs, squash merges, CI green (app: format, analyze, test, package tests, debug APK; firmware: host tests). Commit messages and PR descriptions end with the attribution lines the session gives.
5. Keep `docs/STATUS.md` current whenever a milestone, hardware result or open problem changes. Firmware docs hold the protocol and bench checklists; mark everything not run as "not yet run".
6. **Protocol changes go through the firmware repo first** (spec, golden bytes, host tests); the app follows. Don't invent UUIDs or layouts. Ask before changing the GATT protocol.
7. Scope agent tasks tightly; say what is out of scope; agents print a short summary and do not push or merge unless told.
8. Be honest about uncertainty and your own mistakes. Don't pad.

Style Nick wants: short answers that lead with the result or the command; tables for comparisons; when Nick pastes serial output, extract the figures that matter and say what they imply and do not prove. Hardware runs are Nick's: give Nick ready-to-run commands first. The project default model is Sonnet (Nick's choice, to save usage).

## 3. Machines, sessions and environment gotchas

- **Ixhel**: Nick's headless Windows box. From a cloud session it is reached through the linked device's Desktop Commander (PowerShell). It has adb (wireless, the Pixel; needs re-enabling after reboots) and `gh`. In that shell `adb` and `gh` are not on PATH: use `C:\Users\Nick\AppData\Local\Android\Sdk\platform-tools\adb.exe` and `C:\Program Files\GitHub CLI\gh.exe`, or refresh PATH from the registry per command (`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`). Clones live in `C:\Users\Nick\source\repos\` (`wmr-companion` is the main one; `wmr-companion-ff12`, `wmr-apk*` look like leftovers, one folder was locked by a process).
- **Install the app on the phone**: the current release is the signed unified APK on the latest `v*` tag, `gh release download <tag> -R nightcinder/wmr-companion -p 'wmr-companion-*-unified-arm64-v8a.apk'`. Release APKs share the project key and update in place; a phone that still holds a pre-0.3.3 debug or locally signed build needs `adb uninstall com.onyxlens.wmr_companion` once first, otherwise Android only says "Something went wrong" (`docs/RELEASE_SIGNING.md`). For a CI debug build, `gh run download <CI run id> -R nightcinder/wmr-companion -n wmr-companion-debug-apks -D <dir>`, then `adb uninstall com.onyxlens.wmr_companion.debug` (each CI debug APK is signed differently, and uninstalling clears app data), then `adb install <dir>\app-base-debug.apk` (or `app-unified-debug.apk`). Check the CI run is green and note its commit.
- **Anya**: Nick's desktop with the full ESP-IDF setup, the ESP32 on COM5, the controllers and the phone. The old way to direct firmware work there was WMR_Bridge issue #3 ("Director", closed 2026-10-22; reopen it if a session on Anya is needed). Firmware changes are now written in project threads without a build there, so **any firmware PR needs Nick to build and flash it**. On Anya's ESP-IDF terminal never replace PATH; append only.
- **Cloud container** (where project threads run): GitHub through the `mcp__github__*` tools or `gh` CLI; no Android SDK, so no APK builds there (CI builds them). Flutter for local format/analyze/test: download `flutter_linux_3.47.7-stable.tar.xz` (the CI version) from storage.googleapis.com, then `git config --global --add safe.directory <sdk>/flutter`.
- PowerShell: a backtick inside a double-quoted string is an escape character; use single-quoted here-strings for text with backticks. Repo files may be CRLF; normalize before multi-line replacements. The `Edit` tool refuses `C:\...` paths. `git worktree remove` can fail with "Filename too long": robocopy /MIR from an empty folder, then delete. Check an agent's log before saying it is running (one died silently on a CLI session limit).
- **Monado config key (FF13).** The XOR key table that de-obfuscates the controller config blob is Monado's `wmr_config_key.h` (1024 bytes, Copyright 2021 Jan Schmidt, BSL-1.0). It is **fetched, never committed**: from `apps/wmr_companion_app`, run `dart run ../../tool/fetch_wmr_config_key.dart` (or `--file <downloaded header>`); it writes the gitignored `apps/wmr_companion_app/assets/monado/wmr_config_key.bin`, which the app bundles on the next build; the BSL-1.0 notice ships as `apps/wmr_companion_app/assets/monado/NOTICE.txt`. CI runs the same script before building the debug APK (a failed download does not fail CI), so the CI APK carries the key and decodes real blocks. `loadConfigKey` reports a missing or wrong-size key as a status, never an exception. This is the project's reading of the licence, not legal advice. Details: `docs/PROTOCOL.md` "FF13".

## 4. Build, flash and test commands

App (`apps/wmr_companion_app`; run these from that directory):
- Format: `dart format --set-exit-if-changed .`
- Analyze: `flutter analyze`
- Test app: `flutter test`
- Package tests:
  - `cd packages/wmr_core && dart test`
  - `cd packages/wmr_companion && dart test`
  - `cd packages/wmr_ble && flutter test`
  - `cd packages/wmr_fusion && dart test`
  - `cd packages/wmr_tracking && dart test`
  - `cd packages/wmr_tracking_android_xr && flutter test`
  - `cd packages/wmr_tracking_viture && flutter test`
  - `cd packages/wmr_tracking_xreal && flutter test`
  - `cd packages/wmr_companion_ui && flutter test`
  - `cd packages/WMRCompanionKit && swift test`
- Example app: `cd example && flutter pub get && flutter test && flutter build apk --debug`
- Build debug APK: `cd apps/wmr_companion_app && tool/build_flavor.sh base` (flavors: `base`, `unified`; CI builds the unified flavor; BLE needs a physical phone)
- Build the unified debug APK: `tool/install_unity_export.sh unified path/to/unityLibrary.zip`, then `tool/build_flavor.sh unified --debug` (the export needs both vendor SDKs and owner-approved redistribution; see `apps/wmr_companion_app/android/unity/README.md`)
- iOS config validation: `flutter build ios --config-only --no-codesign` (and in `example/`)

Firmware (Anya, ESP-IDF PowerShell; ESP-IDF v6.1 at `C:\esp\v6.1\esp-idf`; BTstack tree `C:\Users\Nick\btstack-wmr`; `btstack-wmr\wmr_bridge` is a plain folder, not a git checkout):

```powershell
$h = "<firmware commit hash>"
$clone = "$env:TEMP\WMR_Bridge-$h"
if (Test-Path $clone) { Remove-Item $clone -Recurse -Force }
git clone https://github.com/nightcinder/WMR_Bridge $clone
git -C $clone checkout $h
git -C $clone log --oneline -1
robocopy $clone C:\Users\Nick\btstack-wmr\wmr_bridge /E /XD .git captures __pycache__ .github venv
Copy-Item $clone\integration\main-CMakeLists.txt C:\Users\Nick\btstack-wmr\port\esp32\main\CMakeLists.txt -Force
cd C:\Users\Nick\btstack-wmr\port\esp32
$env:EXAMPLE = "wmr_bridge"        # without it the LE Counter example builds
idf.py -B build-wmr-bridge build
idf.py -B build-wmr-bridge -p COM5 -b 115200 flash monitor
```

Robocopy exit codes below 8 mean success and it deletes nothing, so files from other commits stay but are harmless unless the copied CMake file lists them. Always re-copy `main-CMakeLists.txt` (new sources are added to it). Run `idf.py` from `port\esp32`, never from inside a build folder; use `-B build-wmr-bridge`. Note: firmware PR #37 landed a one-command build/flash framework (`tools/firmware/build.py`) and browser installer, which will supersede manual robocopy steps. Controller addresses are no longer compiled in (discovery by name, stored in NVS). Run sheets with exact steps for experiments are in `WMR_Bridge/docs/runs/sheets/`.

Phone side: MTU 517 and High connection priority are needed every connection (the bridge forgets subscriptions, MTU and priority at disconnect). The app now requests MTU 517 itself; on Android 14+ the stack drives the MTU and may ignore the request, so check the negotiated value on the Connect screen. nRF Connect is the reference client for hand-driven checks.

## 5. State, as of this handoff

Refreshed 2026-10-27. The "checked" column is strictly what Nick reported on hardware.

| Area | Built | Checked on hardware |
|---|---|---|
| Current release (`v0.2.1`, 2026-10-27) | Tag `v0.2.1` → `58b5c40`; `wmr-companion-0.2.1-unified-debug.apk` carries one shared VITURE 0.9.0 + XREAL 3.1.0 Unity runtime selected at run time; owner approved SDK redistribution and supplied the export (ONY-354); debug-signed; app `0.2.1+3`, all twelve Dart packages `0.2.1` | **No hardware run.** Vendor dispatch, tracking rates and permissions are unverified; the approved base fallback was not used |
| Reusable Flutter library (ONY-41) | Phases 1–4 merged on `main` (`packages/wmr_core` #39, `packages/wmr_companion` facade #41, `packages/wmr_ble` #42, `example/` host #43); phase 5 iOS example compile / run sheet (#44); phase 7 UI package merged (#45) | Android debug APK connects and streams on hardware (user-reported); the app drives its real connection through the facade. iOS device run not yet done |
| iOS companion framework & probe (ONY-38) | `packages/WMRCompanionKit` Swift framework, SwiftUI probe (`tool/ios_probe`), iOS 18 deployment target, macOS CI compile job (#37, #44) | Unit-tested and CI-compiled; **no iOS device run has happened** |
| Multi-bridge support (ONY-18, PR #34) | Concurrent multi-bridge connections (e.g. Left and Right ESP32 bridges), merging notification streams into shared hand pipelines; Connect screen UI and Riverpod providers updated | Fake/unit tested; **not yet run on hardware** (needs second ESP32) |
| Native Android GATT probe (M7.1, PR #36) | Native Android GATT probe app (`tool/gatt_probe`) and CI job for latency baseline | Built and unit tested; not yet run on hardware |
| Latency run sheet v2 (M7.2, PR #35) | Run sheet with Flutter vs native decision rule in `docs/LATENCY.md` | Doc landed; waiting for sitting |
| Stick settings persistence (ONY-12, PR #30) | Stick calibration and dead zone persistence across app restarts | Yes (user-reported working) |
| App debug loss & signal quality (PR #29) | Show report loss % and BLE signal quality in debug panel | Yes (user-reported) |
| Live fusion filter tuning (PR #33) | Madgwick beta & Mahony gains live tuning in debug screen | Built; not yet run on hardware |
| Trigger press/release hysteresis (PR #32) | Trigger threshold hysteresis in gamepad mapping | Built; not yet run on hardware |
| FF14 batched stream (firmware + app) | App default stream (#12); requests ATT MTU 517 on every connect (#15, up to 9 records per batch) | 479/479 pings answered in 2026-10-22 round-trip run on FF14 at MTU 517 (user-reported) |
| FF15 echo round trip in latency screen | Characteristic FF15 and latency screen round trip with CSV/JSON export; PR #28 added no-stream latency mode and stream selector | 479 of 479 pings answered, round trip min 22.4, p50 40.8, p95 72.8, p99 97.1, max 151.9 ms; ESP32 turnaround p50 0.43 ms (user-reported); no-stream mode not yet run on hardware |
| FF13 config blob & fusion calibration | Real config blocks read with CRC OK; IMU calibration applied behind per-hand switch in fusion (#27, default off) | Decode verified on real blocks (user-reported); fusion IMU calibration not yet run on hardware |
| Discovery by name (firmware) | Firmware auto-discovers controllers by name | D1-D11 reported passed (user-reported) |
| Firmware 2026-10-23 merges (WMR_Bridge) | Single-hand bridge mode `WMR_CFG_BRIDGE_HANDS`/`WMR_CFG_BLE_NAME` (#33); one-command build/flash framework and browser installer (#37); version reporting over FF16 and console 'v' (#38); run sheets for multi-bridge (#34), tracking quality (#35), robustness (#36) | Host tested / CI verified; hardware sittings pending |

### The main open problem: upstream report loss

Reports are lost between the controller and the ESP32 (Classic Bluetooth), before sequence numbers exist; it shows in `dev_missing`/`last5s` from the controller tick deltas. All figures user-reported, 2026-10-22, FF14 at MTU 517 with a phone streaming unless stated:

| Setup | LEFT | RIGHT |
|---|---|---|
| No phone | 9 to 13 % | 9 to 13 % |
| Both controllers connected | 18 to 20 % | 18 to 20 % |
| LEFT alone | ~0.5 % | - |
| RIGHT alone | - | ~10.8 % |

- LEFT's loss is about zero alone and about 19 % with RIGHT connected; RIGHT has about 10 % of its own. In a long run RIGHT fell from ~20 % to ~11 % the moment LEFT fell asleep.
- **Working hypothesis, not proven:** the two Classic links and the BLE link contend for the ESP32's single 2.4 GHz radio transceiver.
- **Multi-bridge cannot deliver "zero loss":** RIGHT alone lost ~10.8 % with one controller and one phone (user-reported). The best multi-bridge can achieve on current evidence is LEFT ~0.5 % and RIGHT ~10.8 %.
- Single-hand firmware mode landed (#33) and companion multi-bridge landed (#34); empirical verification requires a sitting with two ESP32s (M12.3 / sitting B).

## 6. Backlog (open issues)

| Repo | Issue | Topic | Current state |
|---|---|---|---|
| WMR_Bridge | #18 | Two-controller contention and multi-bridge | Single-hand bridge mode merged (#33); app multi-bridge merged (#34). Flasher variants and browser installer merged (`WMR_Bridge` #40), per-bridge attribution merged (#51), per-bridge auto-reconnect merged (#60). Open: two-bridge hardware sitting (M12.3 / Sitting B, parked — no second Classic ESP32) |
| WMR_Bridge | #19 | Unknowns in `docs/DECODING.md` | Deep dive into Monado decoding merged (#26); tracking quality run sheet merged (#35). Open: hardware sitting M12.2 / Sitting A |
| WMR_Bridge | #20 | Build/flash framework and browser installer | One-command `build.py` and browser installer variants landed (`WMR_Bridge` #40) and hosted at `https://nightcinder.github.io/WMR_Bridge/` (`v0.1.0-rc1`); M13.1 prerelease done |
| wmr-companion | #19 | iOS build | **Superseded by ONY-38 and ONY-41.** iOS 18 settled as floor, both platforms in v1; `WMRCompanionKit`, probe, and macOS CI compile check landed (#37, #44) |
| wmr-companion | #20 | `universal_ble` gaps | Android GATT probe built (#36); latency run sheet v2 with decision rule merged (#35). Open: hardware sitting A (M12.2) |
| wmr-companion | ONY-41 | Reusable Flutter library | Phases 1–4 merged on `main` (#39, #41, #42, #43); phase 5 CI compile merged (#44); phase 7 UI package merged (#45); phase 7b HID Android package merged (#48); release hygiene merged (#49/#50/#52/#54). Open: iOS device run (device gate waived for `0.1.0`) |
| Both | ONY-56 | FF16 firmware version reporting | Firmware reports packaged version over FF16 (`WMR_Bridge` #38); app/facade `WmrProtocolVersion` and feature matrix landed in #46 |

Parked ideas: ESP32 as BLE HID gamepad (HOGP); 6DoF / camera fusion (`docs/CAMERAS.md`); single-ESP32 radio tuning (V1 stagger, coex flags); non-Flutter SDK products.

## 7. Suggested next steps, in order

All milestone planning and ordering is governed by **ONY-50's plan document** (`/PAP/issues/ONY-50#document-plan`). Do not invent a competing ordering. The milestones in sequence:

### M10 — Library v1: close the package tree and freeze the API
*Question: can a fresh Flutter app add one dependency, read `GamepadState`, and know which firmware it needs?*
- **10.1 Merge PR #45** (UI package `wmr_companion_ui`, reviewed in ONY-52) — **merged on 2026-10-23**.
- **10.2 Phase 7b**: `wmr_companion_hid_android` extracted from `apps/wmr_companion_app/lib/hid/` and merged (#48).
- **10.3 `WmrProtocolVersion` + FF16** (ONY-56): read the bridge's packaged version, expose it on the link snapshot, and publish the FF11–FF16 feature matrix (skip unknown records, never fatal) — **merged (#46)**.
- **10.4 Release hygiene**: pub workspace, per-package CHANGELOG and version policy, `dart pub publish --dry-run` in CI, export-boundary test per package — **merged (#49/#50/#52/#54, `docs/PUBLISHING.md`)**.
- **10.5 App placement decision**: move to `apps/wmr_companion_app` — **merged (#53)**.
- **10.6 Phase 8 publish**: pub.dev release, only if the owner wants public publishing — **on owner hold**.

### M11 — Two bridges as a product: flash them, tell them apart, keep them
*Question: can someone flash two boards as LEFT and RIGHT without ESP-IDF, see per-bridge figures, and have both reconnect on their own?*
- **11.1 Flasher variants**: `build.py --variant both|left|right` on firmware, name artifacts/manifests per variant, tests, document in `docs/FLASHING.md` — **merged (`WMR_Bridge` #40)**.
- **11.2 Browser installer**: offer all three images from one page — **merged, hosted at `https://nightcinder.github.io/WMR_Bridge/` (`v0.1.0-rc1`)**.
- **11.3 Per-bridge attribution**: end-to-end `bridgeId` on records, stats, link snapshots and latency exports; per-bridge rows in debug and latency screens — **merged (#51)**.
- **11.4 Auto-reconnect**: per-bridge auto-reconnect, HID output resuming without Stop/Start — **merged (#60 / ONY-101)**.
- **11.5 Run sheet update**: `docs/runs/sheets/multi-bridge.md` updated to flasher variants (`WMR_Bridge` #40).
- **Open**: hardware bench verification (Sitting B′ / Sitting B).

### M12 — The verification campaign: turn six run sheets into one answer
*Question: of everything merged since 2026-10-22, what actually works?*
- **12.1 Campaign index**: single index in `WMR_Bridge` `docs/runs/README.md` ordered by reflash cost — **merged (#42)**.
- **12.2 Sitting A (one bridge, no reflash)**: latency v2 (app vs probe) + tracking quality.
- **12.3 Sitting B (two bridges)**: multi-bridge A/B/A/B protocol, twice on separate power-ups (needs a second ESP32) — **parked, no second Classic ESP32**.
- **12.4 Sitting C**: robustness soak + gamepad HID checklist on a PC.
- **12.5 Write-ups**: #18 disposition, M7 decision, M8 defaults, STATUS in both repos.
- **Sitting P (Pi bridge)**: Pi bridge hardware verification (Pi being bought).
- **Sitting R (one board)**: RIGHT-alone asymmetry (`right-asymmetry.md`, `WMR_Bridge` #41).
- **Sitting B′ (one board)**: one board flashed `--variant left`.
- **Close-out**: remaining not-yet-run checks (WMR_Bridge `docs/runs/sheets/closeout.md`).

### M13 — Release and distribution
*Question: can a stranger get a working bridge and a working host app from the two repos?*
- **13.1 Tagged firmware release** with packaged manifest and FF16 version; installer on GitHub Pages — **`v0.1.0-rc1` prerelease and hosted browser flasher are live (M13.1 prerelease done; plain `v0.1.0` waits on M12)**.
- **13.2 Compatibility matrix** published in both repos, keyed on FF16 version — **merged (#59, `WMR_Bridge` #45 & #49)**.
- **13.3 Bridge security decision** in `docs/SECURITY.md` — **recorded for 0.2** (unauthenticated test bridge; Pi secure boot deferred to 0.3), `WMR_Bridge` #64.
- **13.4 README rewrite** in both repos around verified hardware results — **open, around M12 results**.
- **13.5 Companion 0.2.1 unified APK** — **done 2026-10-27**: tag `v0.2.1` at `58b5c40`, unified VITURE+XREAL debug APK with the owner-approved export; debug signing, no hardware validation and the SDK redistribution approval are in the release notes.

### M14 — Linux / Raspberry Pi Wi-Fi host bridge
*Question: does moving the host bridge to a Raspberry Pi over 5 GHz Wi-Fi eliminate upstream radio contention?*
- **14.1 `packages/wmr_ws`**: WebSocket transport implementing `BleTransport` seam over `ws://<host>:8765/wmr` (merged in #61).
- **14.3 App Wi-Fi bridge entry**: host:port entry, token auth, TLS switch, and loopback checks (merged in #62).
- **14.5 Companion docs and publish order**: align docs and publishing waves for seventh package `wmr_ws`; record that `BleTransport` is GATT-shaped and keeps its name for `0.1.0` (owner decision on ONY-146).
- **P1–P10 hardware verification**: physical Raspberry Pi testing sitting (P6 upstream loss comparison); Wi-Fi link is host-tested/loopback-only until then.

### M15 — PSVR2 Sense controller framework
- **15.1 Firmware framework** merged in `WMR_Bridge` #46 (opt-in `WMR_CFG_PSVR2_SUPPORT=0` by default to preserve DRAM headroom).
- **15.2–15.4 parked** — the owner has no PSVR2 controllers.

## 8. Lessons from this session (so you don't repeat them)

- A firmware PR branched before another merged silently dropped the other PR's changes in files both touched (WMR_Bridge #14 removed #13's CI steps and checklist; fixed by #15). After a merge, compare the merged diff with what you expected.
- Check that a log really contains what you think: one "LEFT alone with the phone" paste had `phone=0` throughout (no phone connected), and one had `sub=0` (no stream subscribed). Read the first `STREAM` block before analysing.
- Run labels from Nick's pastes can be offset from yours; confirm which run is which before drawing conclusions. Say which firmware hash was flashed when comparing runs.
- Several features are merged but not yet run on a phone (section 5). Do not describe them as working.

## 9. Where the raw material is

| What | Where |
|---|---|
| Milestone plan (M10–M15) | `/PAP/issues/ONY-50#document-plan` |
| Library design & phases | [docs/LIBRARY.md](docs/LIBRARY.md) |
| Hardware results and open problems | [docs/STATUS.md](docs/STATUS.md) |
| Current release, flavors and unified export | [`v0.2.1` release](https://github.com/nightcinder/wmr-companion/releases/tag/v0.2.1), [docs/tracking/BUILDS.md](docs/tracking/BUILDS.md), [`apps/wmr_companion_app/android/unity/README.md`](apps/wmr_companion_app/android/unity/README.md) |
| Architecture and data flow | [docs/PLAN.md](docs/PLAN.md) |
| Latency test runs and decision rule | [docs/LATENCY.md](docs/LATENCY.md) |
| Native iOS kit (WMRCompanionKit) | [docs/IOS.md](docs/IOS.md), `packages/WMRCompanionKit` |
| Run sheets and raw logs | WMR_Bridge `docs/runs/` |
| Headset camera research for 6DoF | [docs/CAMERAS.md](docs/CAMERAS.md) |
| Headset head/hand tracking research and 6DoF framework | [docs/TRACKING.md](docs/TRACKING.md) |
| Firmware checklists | WMR_Bridge `docs/TESTING.md` |

## 10. Standing decisions and facts from project memory

- **iOS scope and floor**: The owner settled **iOS 18 as the floor and both platforms in v1 scope** (`docs/LIBRARY.md` §13). "iOS is deferred" is no longer the project decision. `packages/WMRCompanionKit` (pure Swift framework), the native SwiftUI probe app (`tool/ios_probe`), and macOS CI compile validation landed in ONY-38 (PR #37) and ONY-41 (PR #44); **no iOS device run has happened yet**.
- **Package split**: The repo is no longer a single Flutter app. It is split into `packages/wmr_core` (pure Dart), `packages/wmr_companion` (public facade), `packages/wmr_ble` (BLE transport), `packages/wmr_ws` (WebSocket transport for the Linux/Pi bridge), `packages/wmr_fusion` (filters), `packages/wmr_tracking` (head/hand tracking + 6DoF fusion, ONY-202), `packages/wmr_tracking_android_xr` (optional default-off Android XR adapter, ONY-212), `packages/wmr_tracking_viture` (optional default-off VITURE Pro Neckband Unity UaaL relay adapter, ONY-213), `packages/wmr_tracking_xreal` (optional default-off XREAL Air 2 Ultra Unity UaaL relay adapter, ONY-214), `packages/wmr_companion_ui` (optional widgets, PR #45), `packages/wmr_companion_hid_android` (optional Android HID output, #48), `packages/WMRCompanionKit` (Swift), and `example/` (minimal host). The app under `apps/wmr_companion_app` is the reference consumer driving its real connection through the facade.
- **0.2.1 companion release**: `v0.2.1` is tagged at `58b5c40` and published with `wmr-companion-0.2.1-unified-debug.apk` (VITURE 0.9.0 + XREAL 3.1.0 in one shared `unityLibrary`, vendor selected at runtime) and the GATT probe APK. The owner approved bundling both proprietary SDKs and supplied the export (ONY-354; export SHA-256 `945bd4254310766313fac81d0daa472408223c82cbee55186bcbcf3d144333b5`). The APK is debug-signed and **has not been run on hardware**; the base fallback was not used. Build with `tool/install_unity_export.sh unified <zip>` then `tool/build_flavor.sh unified --debug`.
- **Protocol defaults and hardware status**: FF14 is the app's default stream and requests ATT MTU 517 on connect. FF15 answered 479/479 pings in a hardware run (round trip p50 40.8 ms, user-reported). The line claiming neither has been run on hardware was wrong. FF16 exists on firmware `main` (#38) and the app reads it once after connect, publishing `WmrProtocolVersion` on `WmrLinkSnapshot` and `WmrCompanion.protocol` (#46).
- **Multi-bridge**: Connecting several bridges concurrently exists (#34 in app, #33 single-hand mode on firmware). It cannot deliver "zero loss" because RIGHT has an independent ~10.8 % loss floor on current evidence.
- **Firmware flashing**: One-command `build.py` and a browser installer landed on firmware (`WMR_Bridge` #37); L/R variant packaging and the three-image browser installer merged (`WMR_Bridge` #40) and are hosted at `https://nightcinder.github.io/WMR_Bridge/` (`v0.1.0-rc1`).
- **Monado key**: Nick chose the fetch script (`tool/fetch_wmr_config_key.dart`); the XOR key table is gitignored and never committed (section 3).
- **FF13 regression history**: Since WMR_Bridge #17 controllers stopped streaming after the config read; fixed by #21 (re-sends enable commands). User-reported working with LEFT ~204/s. Test C7 (`WMR_CFG_FF13_READ=0`) is still not run.
- **FF13 IMU calibration**: Applied behind a per-hand switch in fusion (#27, default off); not yet verified on hardware.
- **Latency screen**: Supports no-stream latency mode (FF15-only echo), stream selector, and configurable ping interval (#28; run sheet in `docs/LATENCY.md`).
- **Loss figures**: User-reported single runs, 2026-10-22, FF14 at MTU 517, phone streaming: LEFT alone ~0.5 %, RIGHT alone ~10.8 %, both connected ~19 % each. RF airtime contention is the working hypothesis, not proven.
- **Permissions**: Merges, deletes, and other outward-facing git actions need Nick's explicit yes. If the permission layer refuses an action, do not work around it; tell Nick.
- **Model default**: Default model for this project was Sonnet (Nick, 2026-10-22) to save usage.

## 11. Cleanup list for Nick

Nick authorised the assistant to clean up on 2026-10-22; items below are what was targeted and re-checked against actual repository state on 2026-10-23. **Do not delete any branch without Nick's explicit yes; keep `main` and anything with an open PR or active work.**

### Branches eligible for deletion after PR merge verification

**Remote branches on GitHub `origin` (`nightcinder/wmr-companion`):**

| Branch | Why it can go |
|---|---|
| `feat/wmr-companion-ui` | PR #45 merged |
| `docs/ios-v1-run-sheet` | PR #44 merged |
| `feat/wmr-example-host` | PR #43 merged |
| `feat/wmr-ble-package` | PR #42 merged |
| `feat/wmr-companion-facade` | PR #41 merged |
| `docs/ony-41-flutter-library` | PR #38 merged |

*(Note: on `nightcinder/WMR_Bridge`, remote branches on `origin` have already been deleted after merges; only `origin/main` remains).*

**Local workspace branches in `wmr-companion`:**

| Branch | Why it can go |
|---|---|
| `app-debug-loss-signal` | PR #29 merged |
| `docs/ony-23-latency-run-sheet-v2` | PR #35 merged |
| `docs/refresh-handoff-status` | PR #31 merged |
| `feat/ony-12-stick-settings-persistence` | PR #30 merged |
| `feat/ony-38-ios-companion-framework` | PR #37 merged |
| `pr35` | PR #35 merged |
| `feat/ony-56-ff16` | PR #46 merged |
| `tool/ony-24-gatt-probe` | PR #36 merged |

**Local workspace branches in `WMR_Bridge`:**

| Branch | Why it can go |
|---|---|
| `docs/contention-2-results` | PR #31 merged |
| `docs/multi-bridge-run-sheet` | PR #34 merged |
| `docs/robustness-run-sheet` | PR #36 merged |
| `docs/tracking-quality` | PR #35 merged |
| `feat/firmware-version` | PR #38 merged |
| `feat/flash-framework` | PR #37 merged |
| `feat/monado-decoding-unknowns` | PR #26 merged |
| `firmware/bridge-hands` | PR #33 merged |
| `firmware/contention-2-flags` | PR #27 merged |
| `firmware/ony14-classic-role-log` | PR #28 merged |
| `fix/duplicate-case-hci-event` | PR #29 merged |
| `fix/policy-exit-sniff-timeout` | PR #30 merged |

### Branches to KEEP (do NOT delete)
- `nightcinder/wmr-companion`:
  - `origin/main` (default branch)
  - local `main`
- `nightcinder/WMR_Bridge`:
  - `origin/main` (default branch)
  - local `main`

### Leftovers on machines (check before removing)
**Ixhel leftovers:**
- `C:\Users\Nick\source\repos\wmr-companion-ff12`
- `C:\Users\Nick\source\repos\wmr-apk*`
- `%TEMP%\wmr-key-test`
- `%TEMP%\wmr-ff13`

**Anya leftovers:**
- `%TEMP%\WMR_Bridge-*` clones from earlier run sheets.
