# Handoff for a new orchestrator

Written 2026-10-22 by the outgoing "director" session for whoever runs this project next, who starts without our conversation. Read `docs/STATUS.md` first (current state and every hardware result), then this file. Where the two differ, STATUS is newer than this page's table of results.

Everything the project owner (Nick) has not reported himself is **not verified on hardware**. Results below are labelled "user-reported" when he pasted or told us the figure.

## 1. What the project is

Windows Mixed Reality motion controllers (LEFT, RIGHT) -> ESP32 running BTstack (Classic Bluetooth HID host) -> BLE GATT -> Android phone running a Flutter app. Goal: debug-mode 3DoF tracking of both controllers, then gamepad-style 3DoF input. Android first, iOS later. Longer-term goal (Nick, 2026-10-22): 6DoF by fusing the controller IMU with a headset's pose or cameras (URXR1, Xreal Aura, Xreal One Pro+Eye, Viture Luma Ultra were researched; none clearly exposes IR-capable tracking frames to apps, so the fallback is fusing the headset pose with the controller IMU). That goal needs the raw, timestamped IMU stream (FF12/FF14) on the camera device, so loss and latency come first.

| Repo | What | Notes |
|---|---|---|
| `nightcinder/WMR_Bridge` | Firmware (C, built inside the BTstack ESP32 port) | Source of truth for the wire protocol (`docs/PROTOCOL.md`). BTstack-derived, non-commercial license. |
| `nightcinder/wmr-companion` | Flutter app, MIT, public | `packages/wmr_fusion` has pure-Dart Madgwick/Mahony. Riverpod, `universal_ble`, `vector_math`. |

GATT service FF10 on the bridge: FF11 raw fragmented HID frames, FF12 decoded 56-byte records, FF14 batches of FF12 records (`version` 2, up to 9 per notification at MTU 517), FF13 controller config blob (read in windows, CRC-32), FF15 echo for round-trip time. FF11/FF12/FF14 are mutually exclusive (a second enable fails with ATT error 0x80; write 0x0000 to the active one first). FF13 and FF15 are independent. App layers: UI -> Riverpod -> `ControllerService` -> (parser + `BleTransport`); `BleTransport` has `UniversalBleTransport` and `FakeTransport`.

## 2. Rules (from the project owner; keep them)

1. **Never state something as verified on hardware unless Nick reported it**; label such results "user-reported". Tests, CI and builds are not hardware results. If you or an agent made a wrong claim, correct it on the issue and in the docs.
2. **Check, don't assume.** Before saying something is merged, running, flashed or pushed, look (GitHub, logs, git). Before comparing hardware runs, check they are comparable (same position, MTU, connection interval, uptime; cumulative counters from long sessions are not comparable with fresh ones; use `last5s`).
3. **Approvals.** Merging PRs, deleting branches and other destructive git actions need Nick's explicit yes in the conversation. Ask once, in one line, then do both. A refused permission is not worked around. Branch deletion is refused by the permission layer in project threads; Nick deletes branches himself on GitHub.
4. Small PRs, squash merges, CI green (app: format, analyze, test, package tests, debug APK; firmware: host tests). Commit messages and PR descriptions end with the attribution lines the session gives.
5. Keep `docs/STATUS.md` current whenever a milestone, hardware result or open problem changes. Firmware docs hold the protocol and bench checklists; mark everything not run as "not yet run".
6. **Protocol changes go through the firmware repo first** (spec, golden bytes, host tests); the app follows. Don't invent UUIDs or layouts. Ask before changing the GATT protocol.
7. Scope agent tasks tightly; say what is out of scope; agents print a short summary and do not push or merge unless told.
8. Be honest about uncertainty and your own mistakes. Don't pad.

Style Nick wants: short answers that lead with the result or the command; tables for comparisons; when he pastes serial output, extract the figures that matter and say what they imply and do not prove. Hardware runs are his: give him ready-to-run commands first. The project default model is Sonnet (his choice, to save usage).

## 3. Machines, sessions and environment gotchas

- **Ixhel**: Nick's headless Windows box. From a cloud session it is reached through the linked device's Desktop Commander (PowerShell). It has adb (wireless, the Pixel; needs re-enabling after reboots) and `gh`. In that shell `adb` and `gh` are not on PATH: use `C:\Users\Nick\AppData\Local\Android\Sdk\platform-tools\adb.exe` and `C:\Program Files\GitHub CLI\gh.exe`, or refresh PATH from the registry per command (`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`). Clones live in `C:\Users\Nick\source\repos\` (`wmr-companion` is the main one; `wmr-companion-ff12`, `wmr-apk*` look like leftovers, one folder was locked by a process).
- **Install the app on the phone**: `gh run download <CI run id> -R nightcinder/wmr-companion -n wmr-companion-debug-apk -D <dir>`, then `adb uninstall com.onyxlens.wmr_companion` (CI APKs are signed differently each run, and uninstalling clears app data), then `adb install <dir>\app-debug.apk`. Check the CI run is green and note its commit.
- **Anya**: Nick's desktop with the full ESP-IDF setup, the ESP32 on COM5, the controllers and the phone. The old way to direct firmware work there was WMR_Bridge issue #3 ("Director", closed 2026-10-22; reopen it if a session on Anya is needed). Firmware changes are now written in project threads without a build there, so **any firmware PR needs Nick to build and flash it**. On Anya's ESP-IDF terminal never replace PATH; append only.
- **Cloud container** (where project threads run): GitHub through the `mcp__github__*` tools (the `plugin:engineering:github` plugin fails with a proxy 403; ignore it); no `gh` CLI; no Android SDK, so no APK builds there (CI builds them). Flutter for local format/analyze/test: download `flutter_linux_3.47.7-stable.tar.xz` (the CI version) from storage.googleapis.com, then `git config --global --add safe.directory <sdk>/flutter`.
- PowerShell: a backtick inside a double-quoted string is an escape character; use single-quoted here-strings for text with backticks. Repo files may be CRLF; normalize before multi-line replacements. The `Edit` tool refuses `C:\...` paths. `git worktree remove` can fail with "Filename too long": robocopy /MIR from an empty folder, then delete. Check an agent's log before saying it is running (one died silently on a CLI session limit).
- **Monado config key (FF13).** The XOR key table that de-obfuscates the controller config blob is Monado's `wmr_config_key.h` (1024 bytes, Copyright 2021 Jan Schmidt, BSL-1.0). It is **fetched, never committed**: `dart run tool/fetch_wmr_config_key.dart` (or `--file <downloaded header>`) writes the gitignored `assets/monado/wmr_config_key.bin`, which the app bundles on the next build; the BSL-1.0 notice ships as `assets/monado/NOTICE.txt`. CI runs the same script before building the debug APK (a failed download does not fail CI), so the CI APK carries the key and decodes real blocks. `loadConfigKey` reports a missing or wrong-size key as a status, never an exception. This is the project's reading of the licence, not legal advice. Details: `docs/PROTOCOL.md` "FF13".

## 4. Build, flash and test commands

App (repo root of wmr-companion): `flutter pub get`, `dart format --set-exit-if-changed .`, `flutter analyze`, `flutter test` (and the `packages/wmr_fusion` tests), `flutter build apk --debug` (CI does this). BLE needs a physical phone.

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

Robocopy exit codes below 8 mean success and it deletes nothing, so files from other commits stay but are harmless unless the copied CMake file lists them. Always re-copy `main-CMakeLists.txt` (new sources are added to it). Run `idf.py` from `port\esp32`, never from inside a build folder; use `-B build-wmr-bridge`. Controller addresses are no longer compiled in (discovery by name, stored in NVS). Run sheets with exact steps for the experiments we did are in the project files `hardware/` folder (`run-sheet-single-controller.md`, `run-sheet-left-coex.md`, `run-sheet-ff14-ab.md`); if that folder is not available to you, the commands above and the protocol of section 6 are enough to rewrite them.

Phone side: MTU 517 and High connection priority are needed every connection (the bridge forgets subscriptions, MTU and priority at disconnect). The app now requests MTU 517 itself; on Android 14+ the stack drives the MTU and may ignore the request, so check the negotiated value on the Connect screen. nRF Connect is the reference client for hand-driven checks.

## 5. State, as of this handoff

All of this is merged; the "checked" column is only what Nick reported.

| Area | Built | Checked on hardware |
|---|---|---|
| FF11/FF12 pipeline, 3D view, axis mapping, gyro rad/s, tick 100 ns | yes | yes (user-reported; accel scale looks like ~10, not 9.81, open) |
| Capture screen | yes | yes |
| FF14 batching (firmware + app, app default) | yes | firmware via nRF Connect only; the app on FF14 and MTU 517 has not been run on a phone |
| FF15 echo (firmware) and round trip in the latency screen | yes | E1-E10 reported passed; first app run: 479/479 pings answered, round trip min 22.4, p50 40.8, p95 72.8, p99 97.1, max 151.9 ms, ESP32 turnaround p50 0.43 ms (user-reported); where the ~40 ms goes is open |
| Discovery by name (firmware) | yes | D1-D11 reported passed (no output pasted) |
| FF13 config blob | firmware (PR #16, #17, fix #21), app client, CRC, de-obfuscation and calibration parsing | both blocks read with CRC OK and gyro/accel calibration decoded on real blocks (user-reported); the calibration is **not applied** to the fusion |
| Gamepad mapping layer, Gamepad screen, settings persistence, Bluetooth HID output | yes | **not run on a phone** |
| Latency screen with CSV/JSON export | yes | one run (above) |

Not yet run (Nick offered to check; none reported): the negotiated MTU on the Connect screen after the 517 request; the 4-step gamepad check in `docs/GAMEPAD.md`; whether the gamepad settings survive an app restart; the Bluetooth HID output on a phone and a host; B4 (phone-side sequence gaps on FF14) and B9 (latency); firmware C7; the remaining firmware checklists in `docs/TESTING.md`.

### The main open problem: upstream report loss

Reports are lost between the controller and the ESP32 (Classic Bluetooth), before sequence numbers exist; it shows in `dev_missing`/`last5s` from the controller tick deltas. All figures user-reported, 2026-10-22, FF14 at MTU 517 with a phone streaming unless stated:

| Setup | LEFT | RIGHT |
|---|---|---|
| No phone | 9 to 13 % | 9 to 13 % |
| Both controllers connected | 18 to 20 % | 18 to 20 % |
| LEFT alone | ~0.5 % | - |
| RIGHT alone | - | ~10.8 % |

- LEFT's loss is about zero alone and about 19 % with RIGHT connected; RIGHT has about 10 % of its own. In a long run RIGHT fell from ~20 % to ~11 % the moment LEFT fell asleep. Working hypothesis, **not proven**: the two Classic links and the BLE link contend for the ESP32's radio. RSSI was not correlated with loss. These are single runs at one position; the single-controller runs used the firmware of WMR_Bridge PR #21.
- Earlier findings: FF12 decimation (N=2, 4) helped RIGHT (BLE airtime matters) and did nothing for LEFT; FF14 batching showed no clear effect (the A/B/A was inconclusive for RIGHT: two identical FF12 runs differed by 9.7 points); `AUTO_LATENCY` on and modem sleep off showed no effect (drifting session). Run-to-run variation is large (baselines 15 to 26 % across resets), while inside one continuous run the 2-minute blocks vary by about 1 point.
- Ideas not yet tried: Classic link parameters (sniff/park/priority), differently scheduled controller connections, seeing whether one controller can be kept off until the other is settled, a second ESP32 or a BT dongle per controller.

## 6. Backlog (open issues)

| Repo | Issue | Topic |
|---|---|---|
| WMR_Bridge | #18 | LEFT/RIGHT extra loss and contention (the main problem, results recorded in the issue) |
| WMR_Bridge | #19 | Unknowns in `docs/DECODING.md` (accel scale, temperature/battery scales, input ranges, stick thresholds) |
| WMR_Bridge | #20 | One-click deploy / browser flasher; ESP32-S3 plus a Bluetooth dongle (S3 has no Classic BT). On hold until the core is solid |
| wmr-companion | #19 | iOS build (deferred: Nick has no Mac/Xcode now) |
| wmr-companion | #20 | `universal_ble` gaps: no PHY API, no on-demand connection-interval query, connection priority Android only; raise upstream or work around behind `BleAdapter` |

Parked ideas (no issue): the ESP32 itself as a BLE HID gamepad (HOGP) as a 3DoF fallback, revisit after the loss is understood (Nick worries about ESP32 radio load); an ESP32-side orientation stream; camera/headset fusion (research saved as [docs/CAMERAS.md](docs/CAMERAS.md)); the connection-interval test; iOS config and CI compile check (pending his decision); bridge security (`docs/SECURITY.md`: no BLE pairing or encryption).

## 7. Suggested next steps, in order

1. Run the close-out checks with Nick: `WMR_Bridge/docs/runs/sheets/closeout.md` has the commands, pass criteria and what to paste back (MTU readout, gamepad checks, settings persistence, optional HID, B4/B9, firmware C7, optional fixed-position round-trip rerun), ordered for the fewest reflashes. Record results as "user-reported" in STATUS.
2. The contention problem (issue #18): decide the next experiment with Nick before writing code. A reference both-connected run on the same build and position should come first each session; compare `last5s` over equal windows after the 30 s settle.
3. Round trip: explain the ~40 ms (runs on FF12, FF11 and with no stream at one fixed position; the app has no stream-off mode yet, and RSSI moved from -69 to -48 dBm during the first run).
4. Apply the FF13 calibration in the fusion (take the pose composition from Monado's `wmr_config_precompute_transforms`; do not re-derive it).
5. Resolve DECODING.md unknowns (#19), then fusion tuning (Madgwick beta is untuned; yaw drifts without a magnetometer).
6. iOS (#19 app) when a Mac is available; `universal_ble` upstream gaps (#20).
7. Later: browser flasher (#20 firmware), 6DoF/camera fusion.

## 8. Lessons from this session (so you don't repeat them)

- A firmware PR branched before another merged silently dropped the other PR's changes in files both touched (WMR_Bridge #14 removed #13's CI steps and checklist; fixed by #15). After a merge, compare the merged diff with what you expected.
- Check that a log really contains what you think: one "LEFT alone with the phone" paste had `phone=0` throughout (no phone connected), and one had `sub=0` (no stream subscribed). Read the first `STREAM` block before analysing.
- Run labels from Nick's pastes can be offset from yours; confirm which run is which before drawing conclusions. Say which firmware hash was flashed when comparing runs.
- Several features are merged but not yet run on a phone (section 5). Do not describe them as working.

## 9. Where the raw material is

| What | Where |
|---|---|
| Run sheets (all of 2026-10-22, plus the close-out sheet) and raw logs, round-trip exports | WMR_Bridge `docs/runs/` (addresses replaced with `ADDR-n`) |
| Headset camera research for the 6DoF goal | [docs/CAMERAS.md](docs/CAMERAS.md) |
| Hardware results and open problems | [docs/STATUS.md](docs/STATUS.md) |
| Firmware checklists with per-check state | WMR_Bridge `docs/TESTING.md` |

Nothing from the earlier tool (project chat, project memory, uploaded files) carries over; everything that mattered is in these repos or in this file.

## 10. Standing decisions and facts from project memory

- Long-term goal (Nick, 2026-10-22): 6DoF through sensor fusion with headset cameras (URXR One, Xreal Aura, Xreal One Pro + Eye, Viture Luma Ultra). That needs the raw timestamped IMU stream (FF12/FF14) on the camera device, so keep the BLE data path and prioritise loss and latency. Research found no device that clearly exposes IR-capable tracking frames to apps; the fallback is fusing the headset pose with the controller IMU ([docs/CAMERAS.md](docs/CAMERAS.md)).
- One-click deploy (a browser flasher) is deferred until WMR_Bridge is near production-ready; an ESP32-S3 plus a Bluetooth dongle is on the back burner (WMR_Bridge #20).
- iOS is deferred: no Mac or Xcode available (wmr-companion #19). Pending decision from Nick: whether to start an iOS config and a CI compile check.
- Parked idea: the ESP32 as a BLE HID gamepad (HOGP), only a 3DoF fallback. Revisit after the loss is understood; Nick worries about ESP32 radio load.
- Monado key: Nick chose the fetch script; the key is never committed (section 3).
- A history of the FF13 regression: since WMR_Bridge #17 the controllers stopped streaming after the config read; fixed by #21 (re-sends Monado's enable commands). User-reported working with LEFT about 204/s. Test C7 (`WMR_CFG_FF13_READ=0`) is still not run.
- Loss figures (user-reported single runs, 2026-10-22, FF14 at MTU 517, phone streaming): LEFT alone about 0.5 %, RIGHT alone about 10.8 %, both connected about 19 % each. Contention between the two Classic links and BLE on the ESP32's radio is the working hypothesis; RIGHT has about 10 % loss of its own. Tracked in WMR_Bridge #18.
- Permissions: merges, deletes and other outward-facing git actions need Nick's explicit yes (he authorised branch and Ixhel cleanup on 2026-10-22, see section 11). If the permission layer refuses an action, do not work around it; tell Nick.
- Model default for this project was Sonnet (Nick, 2026-10-22) to save usage.

## 11. Cleanup list for Nick

Nick authorised the assistant to clean up on 2026-10-22; items below are what was targeted. If a line is still here and the thing still exists, it was not done.

**Branches (check the PR is merged first; keep `main` and anything with an open PR):**

| Repo | Branch | Why it can go |
|---|---|---|
| WMR_Bridge | `claude/project-thread-5z6njd` | PRs #16, #17, #21, #22 merged |
| WMR_Bridge | `claude/project-thread-6pi7k2` | after PR #23 (docs handoff) is merged |
| wmr-companion | `claude/project-thread-5z6njd` | PRs #21, #23 merged |
| wmr-companion | `claude/project-thread-dt8m36` | PRs #9, #14, #24 merged |
| wmr-companion | `claude/project-thread-vrlh8e` | PRs #10, #13, #16 merged |
| wmr-companion | `claude/project-thread-6pi7k2` | after the handoff PR is merged |

**Ixhel leftovers** (look inside each before deleting; for locked or long-path folders use `robocopy <empty> <folder> /MIR`, then remove the folder):

- `C:\Users\Nick\source\repos\wmr-companion-ff12`
- `C:\Users\Nick\source\repos\wmr-apk*`
- `%TEMP%\wmr-key-test`
- `%TEMP%\wmr-ff13`

On Anya, `%TEMP%\WMR_Bridge-*` clones from the run sheets can also go.
