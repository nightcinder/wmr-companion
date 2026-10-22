# Project status

Last updated: 2026-10-22. This page is the entry point: what the project is, what works, what has actually been checked on hardware, what is open, and what comes next. Anything not marked "checked" has not been run on hardware.

## What this project is

A pipeline from Windows Mixed Reality motion controllers to an Android phone, built to end in gamepad-style 3DoF input:

```
WMR controller (L / R)                ESP32 (BTstack)                         Phone (Flutter app)
  Classic BT HID, ~200 Hz  ---->  decode IMU/buttons, bounded queue  ---->  BLE notify FF11 raw / FF12 decoded
                                  repo: nightcinder/WMR_Bridge             fuse (Madgwick/Mahony), debug 3D view
                                                                           repo: nightcinder/wmr-companion
```

- **WMR_Bridge** (firmware, C, BTstack on ESP32): connects to both controllers over Classic Bluetooth HID, optionally decodes the IMU and inputs, and serves them over a BLE GATT service. Source of truth for the wire protocol.
- **wmr-companion** (this repo, Flutter): connects to the bridge, reassembles or parses the stream, fuses orientation on the phone, shows a debug 3D view and link statistics, and records raw captures.
- Android first, iOS later. Debug-mode 3DoF tracking first, gamepad mapping later.
- Third-party: `universal_ble` (BLE), `vector_math`, Riverpod, Flutter. The firmware is derived from BlueKitchen BTstack and keeps its non-commercial license; this app is MIT.

## How the work is run

- Two repos, small PRs, squash merges, CI on both (app: format, analyze, test, package tests, debug APK artifact; firmware: host tests).
- Firmware work needing the real ESP setup is done by a session on the desktop machine, directed through the "Director" issue (WMR_Bridge issue #3). App work is done by headless agent sessions in git worktrees.
- Hardware runs (flashing, controllers, phone) are done by the project owner, who pastes serial and app output; results are recorded in the docs as "user-reported". Agents do not flash and do not describe anything as verified unless a hardware result was reported.

## Current state

### Milestones (see [PLAN.md](PLAN.md))

| # | Milestone | State |
|---|---|---|
| 1 | Scaffold, CI, fake transport, debug 3D view on synthetic data | Done |
| 2 | Scan/connect, subscribe, parse, show raw values | Done; used on hardware |
| 3 | Real orientation from the decoded FF12 stream, stats panel | Done (merged); orientation checked visually on hardware, see below |
| - | Raw capture screen (capture_ble.py-format files) | Done; used on hardware |
| - | FF14 batched stream (parser, three-way exclusion, Batched FF14 mode, fake bridge) | In review; tests only, not run on hardware. Firmware FF14 not run on hardware either |
| 4 | Latency screen and CSV export | Built, not run on hardware: inter-arrival, sequence gaps, tick-based loss, one-way delay variation (from FF12 `rx_time_us`), CSV + JSON export ([LATENCY.md](LATENCY.md)). No true round trip (needs firmware issue #1) |
| 5 | Decide Flutter vs native hot path | Not started; waiting for latency data |
| 6 | iOS build, then gamepad-style mapping | iOS not started. In-app gamepad mapping layer and Gamepad screen built, not run on hardware ([GAMEPAD.md](GAMEPAD.md)); output to the OS or another device not decided |

### What has been checked on hardware (user-reported)

| Item | Result |
|---|---|
| FF12 `device_ticks` unit | 100 ns (ticks/wall about 1.0016 and 1.0083); consecutive records about 4.99 ms apart, about 200 Hz nominal |
| Gyro scale | rad/s |
| Accel magnitude at rest | about 9.9 to 10.2 (so the scale is about 10, not 9.81; open) |
| FF11/FF12 mutual exclusion | Second enable refused with ATT error 0x80; switching by writing 0 to the active CCC first works; below MTU 59 nothing is sent and `mtu_skip` counts; recovery after MTU raise works |
| Axis mapping (sensor to 3D view) | Checked visually in the app's 3D view: world X right = -sensor Y, world Y up = +sensor X, world Z toward user = +sensor Z. Not measured numerically |
| Phone transport | MTU 517 with High priority; no fragment errors, no sequence gaps on the phone in captures |

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

Details and the raw numbers: WMR_Bridge `docs/DECODING.md` ("Investigation notes: upstream report loss") and `docs/TESTING.md`.

### Other open items

| Item | Where |
|---|---|
| Accel scale 9.81 vs 10; temperature and battery scales; buttons, trackpad, trigger ranges | WMR_Bridge `docs/DECODING.md` "Unknown" |
| Stick rest offset (RIGHT y about 0.148 at rest): dead zone / learned centre | App follow-up (in progress) |
| Missing-report definition differs between app and firmware | App follow-up (in progress) |
| Yaw drifts (no magnetometer); gyro bias estimated from the first stationary second | Known limitation |
| FF13 controller calibration blob | Design only, not implemented |
| Echo characteristic for true round-trip latency (the app's latency screen measures one-way delay variation only) | WMR_Bridge issue #1 |
| Controller discovery by name instead of compiled-in addresses | WMR_Bridge issue #2 |
| No BLE pairing or encryption on the bridge | WMR_Bridge `docs/SECURITY.md` |
| `universal_ble` gaps (PHY, connection interval readout) to raise upstream | [PROTOCOL.md](PROTOCOL.md) "universal_ble coverage" |
| Remaining firmware bench checklists (FF12 5-7, 11, 12, 15-18; L1-L5; X-series done) | WMR_Bridge `docs/TESTING.md` |

## Roadmap

Near term:
1. FF14 batching: firmware merged (`8f5921a`, not run on hardware); app support in review. Next: firmware bench checks B1-B12 and the FF12/FF14 A/B/A comparison at one fixed position (WMR_Bridge `docs/TESTING.md`), first with nRF Connect, then B4/B9 with the app.
2. Coexistence experiments for LEFT's extra loss (`AUTO_LATENCY`, modem sleep), A/B/A at a fixed position.
3. App: stick dead zone and learned centre; unified missing-report definition; surface link quality (loss %, rssi, lq) in the debug panel.

Then:
4. Latency runs on hardware with the latency screen (milestone 4, built); firmware echo (issue #1) for true round trip.
5. Calibration (FF13 or phone side), fusion tuning, optional magnetometer-free yaw handling.
6. Controller discovery by name (issue #2), bridge security.
7. iOS build; gamepad: hardware check of the in-app mapping (GAMEPAD.md checklist), then the chosen output stage (Bluetooth HID device, Wi-Fi/DSU, ...; see GAMEPAD.md).

## Where things are

| Topic | File |
|---|---|
| Plan and architecture rules | [PLAN.md](PLAN.md), `CLAUDE.md` |
| App-side protocol decisions, FF12 in the app, axis mapping | [PROTOCOL.md](PROTOCOL.md) |
| Raw capture format and screen | [CAPTURE.md](CAPTURE.md) |
| Latency screen, CSV/JSON export format | [LATENCY.md](LATENCY.md) |
| Gamepad mapping, settings, output options | [GAMEPAD.md](GAMEPAD.md) |
| Firmware wire protocol (source of truth) | WMR_Bridge `docs/PROTOCOL.md` |
| Decoding, timing, loss investigation, unknowns | WMR_Bridge `docs/DECODING.md` |
| Firmware counters and log lines | WMR_Bridge `docs/COUNTERS.md` |
| Bench checklists | WMR_Bridge `docs/TESTING.md` |
| Windows build and flash | WMR_Bridge `docs/BUILD_WINDOWS.md` |
