# WMR Companion App: Project Plan (for Claude Code)

> Current state, hardware results and the roadmap live in [STATUS.md](STATUS.md). This file is the plan and architecture reference; where the two differ, STATUS.md is newer. Packaging the pipeline as reusable Flutter packages is framed in [LIBRARY.md](LIBRARY.md).

## Goal
A Flutter library and reference app (Android and iOS both in v1 scope, iOS 18 floor; see `docs/LIBRARY.md` §13) that connects over BLE GATT to ESP32 firmware (BTstack) exposing WMR controllers, and:
1. Shows live 3DoF orientation of each controller in a **debug mode**.
2. Measures BLE latency/jitter so we can decide whether Flutter + `universal_ble` is good enough or the hot path needs native (Kotlin/Kable).
3. Later: turns the data into gamepad-style input on the phone.

This is a **test harness first**. Prefer simple and measurable over polished.

## Non-goals (for now)
- Shipped 6DoF / positional tracking, Monado XR integration on the phone, desktop/web targets, app store polish. A tracking seam and head-relative fallback exist in `packages/wmr_tracking` ([TRACKING.md](TRACKING.md)); no headset has been tested on hardware.

## Architecture
Keep layers separate so the BLE layer can be swapped without touching the rest.

```
UI (screens, widgets)
  -> State (Riverpod providers)
    -> ControllerService   (per-controller stream of ControllerState)
      -> Protocol layer    (pure Dart: reassembler -> WMR report decoder -> fusion)
      -> BleTransport      (seam interface: GATT-shaped; name settled for 0.1.0)
           -> UniversalBleTransport   (default BLE, uses universal_ble)
           -> WmrWsTransport          (Wi-Fi WebSocket to Linux/Pi daemon; host-tested/loopback-only)
           -> FakeTransport           (synthetic packets, for tests/UI dev)
           -> (later) NativeTransport via platform channel, if latency demands it
```

Rules:
- `BleTransport` is an abstract class: scan, connect, discover, subscribe(characteristic) -> Stream<Uint8List>, write, disconnect, plus connection info (MTU, RSSI, connection interval/PHY where available). Note: `BleTransport` is currently GATT-shaped (UUIDs, CCC subscription, read/write characteristics). `WmrWsTransport` maps WebSocket messages to this seam without changing `ControllerService`. The name is settled: the project owner decided on ONY-146 to keep `BleTransport` as-is for 0.1.0 (it wraps third-party libraries), rather than rename it to e.g. `WmrTransport` or `BridgeTransport`; no rename.
- Parser is pure Dart, no Flutter imports, fully unit tested with golden byte arrays.
- Timestamp every received notification with a monotonic `Stopwatch` **at the transport boundary** (as early as possible) and carry it in the packet object.
- Heavy work (fusion, stats) must not block the UI isolate. Start on the main isolate, but keep it behind interfaces so it can move to a worker isolate.

## Repo layout
```
wmr-companion/
  apps/wmr_companion_app/
    lib/
      main.dart
      app.dart
      ble/            # universal_ble adapter/transport
      services/       # app-side config report, key store and settings wiring
      ui/
        scan/         # scan + connect screen
        controller/   # live controller view (buttons, axes, battery)
        debug/        # 3DoF view + stats panel + stream settings
        capture/      # guided raw capture (FF11)
        latency/      # latency test screen and CSV/JSON export (docs/LATENCY.md)
        gamepad/      # gamepad mapping debug screen (docs/GAMEPAD.md)
    test/
  packages/wmr_core/    # pure Dart: protocol, domain, BleTransport, controller services
  packages/wmr_companion/    # public facade for host apps
  packages/wmr_ble/          # universal_ble adapter/transport and lifecycle hook
  packages/wmr_companion_ui/ # optional orientation/link/stats/gamepad widgets
  packages/wmr_companion_hid_android/ # optional Android Bluetooth HID output
  packages/wmr_ws/      # pure-Dart WebSocket transport for Linux/Pi Wi-Fi daemon
  packages/wmr_fusion/  # pure-Dart Madgwick and Mahony
  packages/wmr_tracking/ # pure-Dart head/hand tracking seam and 6DoF controller fusion
  packages/WMRCompanionKit/ # native Swift framework: iOS 18+, macOS 12+, visionOS 1+ CoreBluetooth & parsers
  example/              # minimal Flutter host app (~20 lines to gamepad state)
  docs/STATUS.md    # current state and roadmap
  docs/PLAN.md      # this file
  docs/PROTOCOL.md  # links to WMR_Bridge docs + app-side decisions
  .github/workflows/ci.yml
  CLAUDE.md
```

## GATT protocol (source of truth: the WMR_Bridge repo)
Firmware: https://github.com/nightcinder/WMR_Bridge. Read `docs/PROTOCOL.md`, `docs/ANDROID.md`, `wmr_bridge.gatt`, `tests/test_protocol.c` and `samples/controller_frames.txt` there before writing any protocol code. Do not invent or restate layouts here; `docs/PROTOCOL.md` in this repo should link to the firmware docs and record only app-side decisions.

GATT characteristics on service `0000FF10-0000-1000-8000-00805F9B34FB`:
- `FF11` (`0000FF11-...`, notify + read): raw fragmented HID stream (46 bytes: 0xA1, report ID 0x01, 44 payload bytes) with 12-byte fragment header. A read returns 16-byte status.
- `FF12` (`0000FF12-...`, notify only): decoded 56-byte records (version 1: hand, buttons, sequence, ESP32 receive time, `device_ticks` at 100 ns, gyro rad/s, accel, temperature, stick, trackpad, trigger, battery). Needs MTU 59+.
- `FF14` (`0000FF14-...`, notify only): batched decoded FF12 records (version 2: 2-byte header + up to 9 records per notification at MTU 517). **The app's default stream.**
- `FF13` (`0000FF13-...`, read + write): controller calibration config blob, read in windows with CRC-32 (WMR_Bridge #16, #17).
- `FF15` (`0000FF15-...`, write without response + notify): echo characteristic for round-trip latency measurement (WMR_Bridge #13).
- `FF16` (`0000FF16-...`, read only): bridge firmware version string (UTF-8 `PROJECT_VER`, at most 31 bytes; WMR_Bridge #38, companion #46). Exposes `WmrProtocolVersion` and feature matrix on the link snapshot.

Stream mutual exclusion: `FF11`, `FF12`, and `FF14` are mutually exclusive (a second enable fails with ATT error 0x80; write 0x0000 to the active CCC first). `FF13`, `FF15`, and `FF16` are independent. Multi-bridge connections (connecting multiple ESP32 bridges concurrently to eliminate Classic Bluetooth radio contention) merge streams into shared per-hand pipelines in `ControllerService`.

What the client can rely on:
- Per-hand sequence numbers (first frame is 1). Gaps mean loss before the BLE stack; they reset only when the ESP32 reboots; compare with modular arithmetic.
- There is **no quaternion and no ESP32 timestamp** in the raw FF11 stream (FF12/FF14 records carry `rx_time_us`). Round trip is measured over the separate FF15 echo characteristic (WMR_Bridge #13).
- Connection sequence (from the firmware's ANDROID.md): connect, requestMtu(517), wait for the negotiated MTU, request High connection priority, discover services, enable notifications (CCC 0x0001). Repeat all of it after every reconnect. Serialize GATT operations and do no heavy work in the notification callback. The bridge serves one phone at a time; the phone can connect to two independent bridges concurrently.

## Decoded stream (FF12 and FF14 batching)
WMR report decoding is done in the ESP32 firmware, not in the app. The layout is fixed in WMR_Bridge `docs/PROTOCOL.md`, mirrored and explained in this repo's [PROTOCOL.md](PROTOCOL.md):
- `FF12`, notify only, 56-byte records. Mutually exclusive with `FF11` and `FF14`.
- `FF14`, notify only, batches of FF12 records (version 2, up to 9 per notification at MTU 517; app default stream).
- Raw IMU is sent, not a quaternion: fusion runs on the phone.
## Orientation pipeline (app side)
1. Per-hand fragment reassembler (pure Dart port of `wmr_reassembler_push`); reuse the firmware's test vectors and sample frames.
2. Decoded samples: the firmware decodes the HID reports (see "Decoded stream" above). The app parses the decoded format and feeds IMU samples to fusion. The raw FF11 frames stay available as a debug view.
3. Fusion: Madgwick or Mahony filter (small pure-Dart implementation) on gyro + accel gives a quaternion per hand. Expect yaw drift; keep the "Reset orientation" button and show drift in debug mode.
4. For FF12, dt comes from the device ticks (100 ns), with wraparound handling and a cap on large steps; arrival time is only used for the raw FF11 path, where it adds jitter-induced error. Axis mapping from sensor to view axes is a configurable table with per-axis flips (default checked visually in the 3D view, user-reported).

## Debug mode (3DoF view)
- Toggle from the controller screen or a settings switch (`debugMode` provider).
- Per controller:
  - 3D orientation widget: rotating axes/cube driven by the quaternion. Use `CustomPainter` + `vector_math` with a simple perspective projection. No game engine for now.
  - Numeric readout: quaternion, Euler (yaw/pitch/roll), angular rate if available.
  - Buttons/axes live state.
- Stats panel:
  - Packet rate (Hz, rolling 1 s window)
  - Inter-arrival time: p50 / p99 / max over a rolling window, plus a small histogram
  - Missed sequence numbers (gap count) and out-of-order count
  - RSSI, MTU, negotiated PHY and connection interval when the platform exposes them
- "Reset orientation" button (zero yaw) to test drift.
- Optional: record to CSV (`phone_ts_us, seq, esp_ts_us, quat..., buttons`) and share via the system share sheet.

## Latency and link-quality test screen
Built; see [LATENCY.md](LATENCY.md). Round trip uses the firmware's FF15 echo; FF12's `rx_time_us` gives one-way delay variation. From the phone alone, measure:
1. Inter-arrival time of complete frames per hand (p50 / p99 / max), against the controllers' roughly 150-180 reports per second per hand.
2. Sequence gaps, out-of-order frames, and incomplete or abandoned frames from the reassembler. This is the "sequence-checking Android receiver" the firmware docs list as not yet provided.
3. Negotiated MTU, requested connection priority, RSSI. Compare a run at MTU 23 (6 notifications per frame) with MTU 61 or more (one per frame).
4. Export results as CSV/JSON.
Round trip comes from the FF15 echo (WMR_Bridge #13, merged, not run on hardware). If p99 jitter is bad, build a bare-Kotlin `BluetoothGattCallback` baseline to separate plugin overhead from radio and connection-parameter effects.
## Packages
- `universal_ble` (BLE; maintained by Rohit, can raise issues upstream)
- `flutter_riverpod` (state)
- `vector_math` (quaternions)
- `share_plus` + `path_provider` (log export)
- `permission_handler` if universal_ble's own permission handling is not enough
- Dev: `flutter_lints`, `mocktail`

Check on pub.dev for current versions before pinning. Verify which Android controls `universal_ble` exposes (connection priority, MTU, PHY) and note any gaps in `docs/PROTOCOL.md` or an issue.

## Platform setup
- **Android**: `BLUETOOTH_SCAN` (neverForLocation), `BLUETOOTH_CONNECT`; `ACCESS_FINE_LOCATION` with `maxSdkVersion=30`. `minSdk` per universal_ble's requirements. Test on a **physical phone**: emulators don't do real BLE.
- **iOS**: `NSBluetoothAlwaysUsageDescription` in Info.plist. Target iOS 18.0+ (owner floor, both Android and iOS in v1 scope; `docs/LIBRARY.md` §13). iOS controls connection interval, so measure rather than assume.

## Milestones
Milestone planning is governed by ONY-50 (see [STATUS.md](STATUS.md) and `HANDOFF.md` §7). The initial milestones (M1–M6) established the baseline pipeline, latency probe, and iOS companion kit. Active work is tracked under M10–M15:

- **M10 — Library v1 & API freeze**: Federated package tree (`wmr_core`, `wmr_companion`, `wmr_ble`, `wmr_ws`, `wmr_fusion`, `wmr_companion_ui`, `wmr_companion_hid_android`, `WMRCompanionKit`), FF16 firmware version reporting (#46), pub workspace and publish readiness (`docs/PUBLISHING.md`), and the reference app move to `apps/wmr_companion_app` (#53). Open: owner approval for final pub.dev publishing (M10.6).
- **M11 — Two bridges as a product**: Multi-bridge connection support in `ControllerService` (#34), per-bridge attribution across records/stats/links/latency export (ONY-70, #51). Complete as engineering: firmware flasher variants and browser installer merged (`WMR_Bridge` #40) and hosted at `https://nightcinder.github.io/WMR_Bridge/` (`v0.1.0-rc1`), per-bridge auto-reconnect and HID resume merged (#60 / ONY-101). Open: hardware bench verification (Sitting B′ / Sitting B).
- **M12 — The verification campaign (Open)**: Turn run sheets into empirical hardware answers across campaign index (`WMR_Bridge` `docs/runs/README.md`, #42): Sitting A (latency v2 + tracking quality), Sitting P (Pi bridge, Pi being bought), Sitting R (RIGHT-alone asymmetry, `right-asymmetry.md` #41), Sitting B′ (one board `--variant left`), Sitting C (robustness + PC HID), Close-out, and Sitting B (two bridges — parked, no second Classic ESP32).
- **M13 — Release and distribution (Open)**: `v0.1.0-rc1` prerelease and hosted browser flasher are live (M13.1 prerelease done; plain `v0.1.0` waits on M12); compatibility matrix is merged in both repos (#59, `WMR_Bridge` #45 & #49, M13.2 done); M13.3 security decision recorded for 0.2 (unauthenticated test bridge; Raspberry Pi secure boot deferred to 0.3). Open: M13.4 README rewrite around M12 results.
- **M14 — Raspberry Pi Wi-Fi host bridge**: WebSocket transport package (`wmr_ws`, M14.1 / #61) behind `BleTransport`, companion app host:port Wi-Fi connection entry (M14.3 / #62), docs and publishing order alignment (M14.5). Open: hardware verification campaign on physical Pi (P1–P10); Wi-Fi link is host-tested/loopback-only until the Pi sitting. `BleTransport` interface is GATT-shaped but keeps its name for 0.1.0 (owner decision on ONY-146, no rename).
- **M15 — PSVR2 Sense controller framework**: Firmware framework merged in `WMR_Bridge` #46 (opt-in `WMR_CFG_PSVR2_SUPPORT=0` by default to preserve DRAM headroom). M15.2–15.4 parked (owner has no PSVR2 controllers).

## GitHub and CI
- Repo: `wmr-companion` (public, MIT), default branch `main`. Squash merges.
- `.gitignore`: merge with the one from `flutter create`; keep `*.keystore`, `key.properties`, `local.properties` ignored.
- `.github/workflows/ci.yml` (add in milestone 1): on push/PR, `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug`, upload the APK as an artifact (so any machine can grab a build without an Android SDK).
- Small commits, conventional messages, one milestone per PR.

## Notes for Claude Code
- Keep `CLAUDE.md` in sync with the architecture rules above and the commands (`flutter analyze`, `flutter test`, `flutter run -d <device>`).
- Ask before changing the GATT protocol; the firmware is the source of truth.
- Keep every test hardware-free by using `FakeTransport`.
