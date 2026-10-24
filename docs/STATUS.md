# Project status

Last updated: 2026-10-24 (updated for M10–M15 milestones and reusable library close-out ONY-41; see [../HANDOFF.md](../HANDOFF.md)). This page is the entry point: what the project is, what works, what has actually been checked on hardware, what is open, and what comes next. Anything not marked "checked" has not been run on hardware.

## What this project is

A pipeline from Windows Mixed Reality motion controllers to an Android or iOS device, built to end in gamepad-style 3DoF input:

```
WMR controller (L / R)                ESP32 (BTstack)                         Phone / Host (Flutter / Swift)
  Classic BT HID, ~200 Hz  ---->  decode IMU/buttons, bounded queue  ---->  BLE notify FF11 raw / FF12 decoded / FF14 batched
                                  repo: nightcinder/WMR_Bridge             fuse (Madgwick/Mahony), debug 3D view
                                                                           repo: nightcinder/wmr-companion
```

- **WMR_Bridge** (firmware, C, BTstack on ESP32): connects to both controllers over Classic Bluetooth HID, optionally decodes the IMU and inputs, and serves them over a BLE GATT service. Source of truth for the wire protocol.
- **wmr-companion** (this repo): federated package tree with seven Dart packages (`packages/wmr_core`, `packages/wmr_companion`, `packages/wmr_ble`, `packages/wmr_ws`, `packages/wmr_fusion`, `packages/wmr_companion_ui`, `packages/wmr_companion_hid_android`) plus Swift `packages/WMRCompanionKit`, a minimal Flutter host (`example/`), and the reference app (`apps/wmr_companion_app`). Connects to the bridge (BLE or Wi-Fi WebSocket), reassembles or parses the stream, fuses orientation on the host, shows a debug 3D view and link statistics, and records raw captures. Note: the Wi-Fi bridge is host-tested/loopback-only until the Pi hardware sitting (see `WMR_Bridge` `docs/PI_BRIDGE.md` and run sheet `docs/runs/sheets/pi-bridge.md`).
- Android and iOS are both in scope for v1 (the owner settled iOS 18 as the floor, `docs/LIBRARY.md` §13). Debug-mode 3DoF tracking first, gamepad mapping later.
- Third-party: `universal_ble` (BLE), `vector_math`, Riverpod, Flutter. The firmware is derived from BlueKitchen BTstack and keeps its non-commercial license; this app is MIT.

## How the work is run

- Two repos, small PRs, squash merges, CI on both (app: format, analyze, test, package tests, debug APK artifact; firmware: host tests).
- Firmware work needing the real ESP setup is done by a session on the desktop machine, directed through project threads (the "Director" issue, WMR_Bridge #3, was closed on 2026-10-22; reopen it if a session on that machine is needed again). App work is done by headless agent sessions in git worktrees.
- Hardware runs (flashing, controllers, phone) are done by the project owner, who pastes serial and app output; results are recorded in the docs as "user-reported". Agents do not flash and do not describe anything as verified unless a hardware result was reported.

## Current state

### Milestones (see [PLAN.md](PLAN.md))

Work is planned across milestones M10–M15 (governed by ONY-50; see `HANDOFF.md` §7 and `docs/PLAN.md`). The earlier milestones (M1–M6: scaffold, GATT stream, 3DoF orientation, latency screen, iOS probe) established the baseline pipeline; active work is organized under M10–M15:

| Milestone | Scope | State |
|---|---|---|
| **M10 — Library v1 & API freeze** | Package extraction, FF16 version reporting, reference app move to `apps/`, publish readiness | Seven Dart packages (`wmr_core`, `wmr_companion`, `wmr_ble`, `wmr_ws`, `wmr_fusion`, `wmr_companion_ui`, `wmr_companion_hid_android`) and Swift `WMRCompanionKit` extracted; FF16 version reading landed (#46); reference app moved to `apps/wmr_companion_app` (#53); pub workspace, strict publish dry-run, and export boundary tests landed (#54; `docs/PUBLISHING.md`). `0.1.0` is on owner hold, and the phase-5 iOS 18 device gate was waived for this release (owner, 2026-10-23) — iOS is CI-compiled but not hardware-verified. **Open:** Publish readiness / final owner authorization to publish to pub.dev (M10.6). |
| **M11 — Two bridges as a product** | Flasher variants, browser installer, per-bridge attribution, auto-reconnect | Multi-bridge support landed in `ControllerService` (#34). Per-bridge attribution on records, stats, links, and latency CSV export landed (#51 / ONY-70). Complete as engineering: firmware flasher variants and browser installer merged (`WMR_Bridge` #40) and hosted at `https://nightcinder.github.io/WMR_Bridge/` (`v0.1.0-rc1`), per-bridge auto-reconnect and HID resume merged (#60 / ONY-101). **Open:** Hardware bench verification (Sitting B′ / Sitting B) remains open. |
| **M12 — The verification campaign** | Empirical hardware verification across campaign index | **Open.** Campaign index (`WMR_Bridge` `docs/runs/README.md`, #42): Sitting A (latency v2 + tracking quality), Sitting P (Pi bridge, Pi being bought), Sitting R (RIGHT-alone asymmetry, `right-asymmetry.md` #41), Sitting B′ (one board `--variant left`), Sitting C (robustness + PC HID), Close-out, and Sitting B (two bridges — parked, no second Classic ESP32). |
| **M13 — Release and distribution** | Tagged release, compatibility matrix, bridge security, documentation | `v0.1.0-rc1` prerelease and hosted browser flasher are live (M13.1 prerelease done; plain `v0.1.0` waits on M12); compatibility matrix is merged in both repos (#59, `WMR_Bridge` #45 & #49, M13.2 done). **Open:** M13.3 security decision (after M12) and M13.4 README rewrite around M12 results. |
| **M14 — Raspberry Pi Wi-Fi host bridge** | WebSocket transport (`wmr_ws`), companion app Wi-Fi entry, Wi-Fi compatibility row, P-campaign | `wmr_ws` package (#61 / M14.1) and app host:port connection UI with TLS/token support (#62 / M14.3) landed. Wi-Fi bridge is host-tested/loopback-only until the Pi hardware sitting (P6). `BleTransport` is GATT-shaped but keeps its name for `0.1.0` (owner decision on ONY-146, no rename). |
| **M15 — PSVR2 Sense controller framework** | PSVR2 Sense support in firmware, opt-in DRAM guard | Firmware framework merged in `WMR_Bridge` #46 (opt-in `WMR_CFG_PSVR2_SUPPORT=0` by default to preserve DRAM headroom). M15.2–15.4 parked (owner has no PSVR2 controllers). |

### What has been checked on hardware (user-reported)

| Item | Result |
|---|---|
| FF12 `device_ticks` unit | 100 ns (ticks/wall about 1.0016 and 1.0083); consecutive records about 4.99 ms apart, about 200 Hz nominal |
| Gyro scale | rad/s |
| Accel magnitude at rest | about 9.9 to 10.2 (so the scale is about 10, not 9.81; open) |
| FF11/FF12 mutual exclusion | Second enable refused with ATT error 0x80; switching by writing 0 to the active CCC first works; below MTU 59 nothing is sent and `mtu_skip` counts; recovery after MTU raise works |
| Axis mapping (sensor to 3D view) | Checked visually in the app's 3D view: world X right = -sensor Y, world Y up = +sensor X, world Z toward user = +sensor Z. Not measured numerically |
| Phone transport | MTU 517 with High priority; no fragment errors, no sequence gaps on the phone in captures |
| FF15 echo round trip | One 120 s run on FF14 at MTU 517, 15 ms interval, both controllers: 479 of 479 pings answered, no timeouts. Round trip min 22.4, p50 40.8, p95 72.8, p99 97.1, max 151.9 ms; ESP32 turnaround p50 0.43 ms, p99 2.3 ms, max 7.5 ms. One run, one position, one phone; details and what it does not show in [LATENCY.md](LATENCY.md) |

### The main open problem: upstream report loss

Reports are lost between the controller and the ESP32 (Classic Bluetooth), before the ESP32 assigns sequence numbers, so sequence numbers cannot show it. It is visible from device-tick deltas (`dev_missing`, `last5s`).

Bench runs of 2026-10-22 (user-reported, controllers still on a table at one position, MTU 517, 15 ms connection interval; `last5s` per hand):

| Run | LEFT | RIGHT |
|---|---|---|
| No phone connected | 9 to 11 % | 9 to 11 % |
| FF12 every report (N=1), first run | 22 to 25 % | 36 % |
| N=1, repeat | 19 % | 28 to 36 % |
| FF12 every 2nd report (N=2) | 18 to 20 % | 14 to 15 % |
| FF12 every 4th report (N=4) | 18 to 20 % | 12 to 13 % |

What this suggests (one position, one session, one ESP32, one phone):

- BLE notification airtime costs RIGHT a lot of reports and the effect repeated. Halving the notification count recovers most of it. FF12 v2 batching (several records per notification, new characteristic FF14) is being built on that basis.
- LEFT loses about 10 percentage points more as soon as a phone streams, independent of N, so its extra loss is not caused by notification volume. Not explained. Candidates still to test: `CONFIG_BTDM_CTRL_AUTO_LATENCY`, Bluetooth modem sleep (steps in WMR_Bridge `docs/BUILD_WINDOWS.md`).
- RIGHT is the weaker link in other measurements too (lower link quality at similar RSSI).
- Distance matters: with the controllers far from the ESP32 the loss was higher.

FF14 against FF12, A/B/A (2026-10-22, user-reported; nRF Connect as the client for every phone run, MTU 517, 15 ms interval, `last5s` mean over 5 s rows from 35 s to 101 s of each run, controllers on the table and not moved at all between runs):

| Run | Stream | LEFT | RIGHT | Notes |
|---|---|---|---|---|
| 0 | no phone | 13.4 % | 11.5 % | LEFT a little above the 9 to 11 % of the earlier no-phone runs |
| 1 | A: FF12, N=1 | 19.5 % | 33.6 % | in line with the earlier N=1 runs |
| 2 | B: FF14 | 20.9 % | 20.7 % | mean batch 6.7 records, max 9, 27 % of batches sent full; about 48 notifications/s against about 300/s on FF12 |
| 4 | A again: FF12, N=1 | 27.1 % | 23.9 % | the second A (the run sheet numbered it 3) |

What this does and does not show:

- FF14 delivered the stream with no queue drops (`drop=0`, queue high-water mark 31, FF12 reached 35 to 36) and the counters add up: `rx = tx + q` per hand, `tx` over both hands equals `records_in_batches` (33995), `notify` equals `batches_tx` (5078). That is B3 and B5 for one run each; B4 (phone-side sequence gaps) was not run.
- RIGHT on FF14 (20.7 %) is below the first FF12 run (33.6 %) and the second FF12 run (23.9 %) is close to it. The second A moved 9.7 points away from the first with the controllers not moved, so run-to-run variation is as large as the FF14 difference and the FF14 effect on RIGHT cannot be separated from it. The direction matches the decimation runs; the A/B/A does not demonstrate it.
- LEFT: 19.5, 20.9, 27.1 % in order. It rose through the session and the FF14 run sits between the two FF12 runs, so FF14 shows no effect on LEFT. This agrees with the earlier finding that LEFT's extra loss does not follow notification volume. LEFT RSSI was about 4 dB weaker in runs 2 and 4 than in run 1 (about -30 and -27 against -26).
- Run 4's cumulative figures include a stretch without a phone, so only `last5s` is comparable.
- Single-controller runs with the phone on FF14 at MTU 517, on the firmware of WMR_Bridge PR #21 (FF13 streaming fix), user-reported, 5 to 8 min each: LEFT alone about 0.5 %, RIGHT alone about 10.8 %, both connected about 19 % each (same build and position). In a long run, RIGHT's loss fell from about 20 % to about 11 % when LEFT went to sleep. Working hypothesis, not proven: the two Classic links and the phone compete for the ESP32's radio. Tracked in WMR_Bridge issue #18 and addressed by multi-bridge support (M11).

Details and the raw numbers: WMR_Bridge `docs/DECODING.md` ("Investigation notes: upstream report loss") and `docs/TESTING.md`.

### Other open items

| Item | Where |
|---|---|
| Accel scale 9.81 vs 10; temperature and battery scales; buttons, trackpad, trigger ranges | WMR_Bridge `docs/DECODING.md` "Unknown" |
| Stick rest offset (RIGHT y about 0.148 at rest): dead zone / learned centre | Done (#7): pure-Dart `StickNormalizer` per hand with configurable radial dead zone (default 0.05), learned rest centre, manual re-centre, and debug controls; not yet tested on hardware ([PROTOCOL.md](PROTOCOL.md) "Stick dead zone and learned rest centre") |
| Missing-report definition differs between app and firmware | Done (#7): tick delta missing-report calculation unified to match firmware (`wmr_devloss.c`: median of deltas within 1.5x 10th-percentile over 256-delta window); not compared against live bridge |
| Yaw drifts (no magnetometer); gyro bias estimated from the first stationary second | Known limitation |
| FF13 controller calibration blob | Firmware merged (WMR_Bridge #16, #17); both blocks read to READY on a bench run (user-reported). App: client, CRC check, de-obfuscation and JSON parsing built and unit tested with synthetic data and now seen on real blocks, a "Read config" button on the debug screen read both blocks over FF13 with CRC OK (LEFT 7147 bytes 8bc13223, RIGHT 7148 bytes 75e8ab85) and decoded gyro and accelerometer calibration with Monado's key (user-reported 2026-10-22; mix matrices near identity, Rt rotations mirrored between hands); the Monado XOR key table is not in the repo; calibration applied behind a per-hand switch in fusion (#27, default off), not yet run on hardware ([PROTOCOL.md](PROTOCOL.md) "FF13 config block in the app") |
| FF16 bridge firmware version | Read-only UTF-8 string with no terminator (at most 31 bytes; WMR_Bridge #38). Read once after connect; publishes WmrProtocolVersion (firmware version and FF11–FF16 feature matrix) on WmrLinkSnapshot and WmrCompanion.protocol (#46; note: HANDOFF.md §5/§10 predates #46 merge). Tested against fake bridge; not yet run on hardware |
| Round trip: where the 40 ms goes (phone write and notification delivery, air, notification traffic). Needs an FF11/FF12 run and a run with no stream at the same position; the screen now has a no-stream latency mode and a stream selector (PR #28, built, **not yet run on hardware**) | [LATENCY.md](LATENCY.md) "First hardware run", "Run sheet" |
| Controller discovery by name instead of compiled-in addresses (done; addresses are stored in the ESP32's NVS) | Firmware merged (WMR_Bridge #14); checks D1-D11 reported as passed by the project owner (user-reported, 2026-10-22, no output pasted) |
| No BLE pairing or encryption on the bridge | WMR_Bridge `docs/SECURITY.md` |
| `universal_ble` gaps (PHY, connection interval readout) to raise upstream | [PROTOCOL.md](PROTOCOL.md) "universal_ble coverage" |
| Remaining firmware bench checklists (FF12 5-7, 11, 12, 15-18; L1-L5; B4, B6-B11; C7; X-series done) | WMR_Bridge `docs/TESTING.md` |
| Checks still not run, with commands and pass criteria | WMR_Bridge `docs/runs/sheets/closeout.md` |

## Roadmap: M10–M15

The roadmap is governed by ONY-50's plan document (`/PAP/issues/ONY-50#document-plan`; see [../HANDOFF.md](../HANDOFF.md) §7 and [PLAN.md](PLAN.md)). The sequence of work:

1. **M10 — Library v1 & API freeze**:
   - Seven Dart packages (`wmr_core`, `wmr_companion`, `wmr_ble`, `wmr_ws`, `wmr_fusion`, `wmr_companion_ui`, `wmr_companion_hid_android`) and Swift `WMRCompanionKit` extracted and tested.
   - FF16 bridge firmware version reading landed in #46 (`WmrProtocolVersion`).
   - Reference app moved to `apps/wmr_companion_app` in #53 (M10.5).
   - Dart pub workspace, export-boundary checks, and strict publish dry-run landed in #54 (`docs/PUBLISHING.md`).
   - **Open:** Publish readiness / final owner authorization to publish to pub.dev (M10.6).
2. **M11 — Two bridges as a product**:
   - Multi-bridge support in `ControllerService` landed (#34).
   - Per-bridge attribution on records, stats, links, and latency CSV export landed in #51 (ONY-70).
   - Firmware flasher variants and browser installer merged (`WMR_Bridge` #40) and hosted at `https://nightcinder.github.io/WMR_Bridge/` (`v0.1.0-rc1`).
   - Per-bridge auto-reconnect and HID resume merged (#60 / ONY-101).
   - Complete as engineering; hardware bench verification (Sitting B′ / Sitting B) remains open.
3. **M12 — The verification campaign (Open)**:
   - Turn run sheets into empirical hardware answers across campaign index (`WMR_Bridge` `docs/runs/README.md`, #42):
     - *Sitting A (one bridge, no reflash):* latency v2 (app vs probe) and tracking quality.
     - *Sitting P (Pi bridge):* Pi bridge hardware verification (Pi being bought).
     - *Sitting R (one board, no purchase):* RIGHT-alone asymmetry (`right-asymmetry.md` #41).
     - *Sitting B′ (one board):* one board `--variant left`.
     - *Sitting C:* robustness soak and gamepad HID checklist on a PC.
     - *Close-out:* remaining not-yet-run checks.
     - *Sitting B (two bridges):* multi-bridge A/B/A/B on two ESP32s — **parked**, no second Classic ESP32.
     - *Write-ups:* #18 disposition, M7 decision, M8 defaults, STATUS in both repos.
4. **M13 — Release and distribution (Open)**:
   - `v0.1.0-rc1` prerelease and hosted browser flasher are live (M13.1 prerelease done; plain `v0.1.0` waits on M12).
   - Compatibility matrix published in both repos keyed on FF16 (#59, `WMR_Bridge` #45 & #49, M13.2 done).
   - **Open:** M13.3 bridge security decision in `docs/SECURITY.md` (after M12).
   - **Open:** M13.4 README rewrite in both repos around verified M12 hardware results.
5. **M14 — Raspberry Pi Wi-Fi host bridge (In progress)**:
   - **M14.1 `packages/wmr_ws`:** WebSocket transport implementing `BleTransport` seam over `ws://<host>:8765/wmr` (merged #61).
   - **M14.3 App Wi-Fi bridge entry:** host:port connection UI, optional token authentication, TLS switch, loopback checks (merged #62).
   - **M14.5 Companion docs and publish order:** Update docs (`README.md`, `STATUS.md`, `PLAN.md`, `LIBRARY.md`, `PUBLISHING.md`) and publish waves for the seventh package `wmr_ws`; record that `BleTransport` is GATT-shaped, and that its name is settled for `0.1.0` (owner decision on ONY-146).
   - **Open:** Empirical P-campaign verification on physical Raspberry Pi hardware (P1–P10). Wi-Fi link is host-tested/loopback-only until the Pi sitting.
6. **M15 — PSVR2 Sense controller framework**:
   - PSVR2 Sense firmware framework merged in `WMR_Bridge` #46 (opt-in `WMR_CFG_PSVR2_SUPPORT=0` by default to preserve DRAM headroom).
   - M15.2–15.4 parked (owner has no PSVR2 controllers).

## Not yet run on hardware (as of 2026-10-23)

Close-out checks reported by the project owner on 2026-10-22 (user-reported, one-line answers, no details): the Connect screen shows MTU 517; the gamepad checks in [GAMEPAD.md](GAMEPAD.md) "worked"; the gamepad settings were saved across an app restart; the flash of `main` worked. C7 (`WMR_CFG_FF13_READ=0`): a `STREAM` paste with both FF13 states 0, `other=0`, and RIGHT streaming at 181/s (`last5s` 10.7 %, one controller only; LEFT had no ACL link). That agrees with C7 for RIGHT, but the build hash was not stated and LEFT was not tested, so C7 is recorded as partly reported. Built and unit-tested only, until reported:

- Bluetooth HID output on a phone and a host (skipped).
- FF14 checks B4 (phone-side sequence gaps) and B9, and B6-B8, B10, B11.
- A round-trip rerun at a fixed position, and on FF12, FF11 and with no stream (the screen now supports all four via PR #28 no-stream latency mode and stream selector; not yet run).
- FF13 IMU calibration applied in fusion behind a per-hand switch (PR #27).
- Stick dead zone, learned rest centre, and unified missing-report definition (PR #7).
- FF16 firmware version read on a live bridge (PR #46).
- Per-bridge attribution on multi-bridge hardware (PR #51).
- Wi-Fi bridge streaming on a physical Raspberry Pi (host-tested / loopback-only with `--replay` in PR #61 and PR #62; pending Pi hardware sitting P1–P10).
- `BleTransport` name: settled. The owner decided on ONY-146 to keep `BleTransport` for `0.1.0` (it is GATT-shaped but wraps third-party libraries); no rename made.

## Where things are

| Topic | File |
|---|---|
| Plan and architecture rules | [PLAN.md](PLAN.md), `CLAUDE.md` |
| Reusable Flutter library: package split, facade API, phases | [LIBRARY.md](LIBRARY.md) |
| Package publishing and dry-run validation | [PUBLISHING.md](PUBLISHING.md) |
| App-side protocol decisions, FF12 in the app, axis mapping | [PROTOCOL.md](PROTOCOL.md) |
| Raw capture format and screen | [CAPTURE.md](CAPTURE.md) |
| Latency screen, CSV/JSON export format | [LATENCY.md](LATENCY.md) |
| Gamepad mapping, settings, output options | [GAMEPAD.md](GAMEPAD.md) |
| Firmware wire protocol (source of truth) | WMR_Bridge `docs/PROTOCOL.md` |
| Decoding, timing, loss investigation, unknowns | WMR_Bridge `docs/DECODING.md` |
| Firmware counters and log lines | WMR_Bridge `docs/COUNTERS.md` |
| Bench checklists | WMR_Bridge `docs/TESTING.md` |
| Run sheets and raw logs | WMR_Bridge `docs/runs/` |
| Handoff (rules, environment, lessons, cleanup list) | [../HANDOFF.md](../HANDOFF.md) |
| iOS companion app framework & native probe | [IOS.md](IOS.md) |
| Headset camera research | [CAMERAS.md](CAMERAS.md) |
| Windows build and flash | WMR_Bridge `docs/BUILD_WINDOWS.md` |
