# WMR Companion App: Project Plan (for Claude Code)

> Current state, hardware results and the roadmap live in [STATUS.md](STATUS.md). This file is the plan and architecture reference; where the two differ, STATUS.md is newer. Packaging the pipeline as reusable Flutter packages is framed in [LIBRARY.md](LIBRARY.md).

## Goal
A Flutter app (Android first, iOS next) that connects over BLE GATT to ESP32 firmware (BTstack) exposing WMR controllers, and:
1. Shows live 3DoF orientation of each controller in a **debug mode**.
2. Measures BLE latency/jitter so we can decide whether Flutter + `universal_ble` is good enough or the hot path needs native (Kotlin/Kable).
3. Later: turns the data into gamepad-style input on the phone.

This is a **test harness first**. Prefer simple and measurable over polished.

## Non-goals (for now)
- 6DoF / positional tracking, Monado XR integration on the phone, desktop/web targets, app store polish.

## Architecture
Keep layers separate so the BLE layer can be swapped without touching the rest.

```
UI (screens, widgets)
  -> State (Riverpod providers)
    -> ControllerService   (per-controller stream of ControllerState)
      -> Protocol layer    (pure Dart: reassembler -> WMR report decoder -> fusion)
      -> BleTransport      (interface)
           -> UniversalBleTransport   (default, uses universal_ble)
           -> FakeTransport           (synthetic packets, for tests/UI dev)
           -> (later) NativeTransport via platform channel, if latency demands it
```

Rules:
- `BleTransport` is an abstract class: scan, connect, discover, subscribe(characteristic) -> Stream<Uint8List>, write, disconnect, plus connection info (MTU, RSSI, connection interval/PHY where available).
- Parser is pure Dart, no Flutter imports, fully unit tested with golden byte arrays.
- Timestamp every received notification with a monotonic `Stopwatch` **at the transport boundary** (as early as possible) and carry it in the packet object.
- Heavy work (fusion, stats) must not block the UI isolate. Start on the main isolate, but keep it behind interfaces so it can move to a worker isolate.

## Repo layout
```
wmr-companion/
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
  packages/wmr_core/    # pure Dart: protocol, domain, BleTransport, controller services
  packages/wmr_fusion/  # pure-Dart Madgwick and Mahony
  test/
  docs/STATUS.md    # current state and roadmap
  docs/PLAN.md      # this file
  docs/PROTOCOL.md  # links to WMR_Bridge docs + app-side decisions
  .github/workflows/ci.yml
  CLAUDE.md
```

## GATT protocol (source of truth: the WMR_Bridge repo)
Firmware: https://github.com/nightcinder/WMR_Bridge. Read `docs/PROTOCOL.md`, `docs/ANDROID.md`, `wmr_bridge.gatt`, `tests/test_protocol.c` and `samples/controller_frames.txt` there before writing any protocol code. Do not invent or restate layouts here; `docs/PROTOCOL.md` in this repo should link to the firmware docs and record only app-side decisions.

The firmware is a **raw pipe**: it does not decode, filter or time-stamp. What the app can rely on:
- Device name `WMR Bridge`, service `0000FF10-0000-1000-8000-00805F9B34FB`, characteristic `0000FF11-...` (notify + read). A read of FF11 returns a 16-byte status, not stream data.
- Notifications are **fragments**: 12-byte header (magic 0x52, hand u8, sequence u32 LE, total_len u16, offset u16, chunk_len u16) plus a chunk. Reassemble per hand using the receiver rules in the firmware doc. A frame is 46 bytes: 0xA1, report ID 0x01, 44 payload bytes (the raw WMR HID input report).
- Per-hand sequence numbers (first frame is 1). Gaps mean loss before the BLE stack; they reset only when the ESP32 reboots; compare with modular arithmetic.
- There is **no quaternion and no ESP32 timestamp** in the raw FF11 stream (FF12/FF14 records carry `rx_time_us`). Round trip is measured over the separate FF15 echo characteristic (WMR_Bridge #13).
- Connection sequence (from the firmware's ANDROID.md): connect, requestMtu(517), wait for the negotiated MTU, request High connection priority, discover services, enable notifications (CCC 0x0001). Repeat all of it after every reconnect. Serialize GATT operations and do no heavy work in the notification callback. The bridge serves one phone at a time.

## Decoded stream (implemented: FF12; planned: FF14 batching)
WMR report decoding is done in the ESP32 firmware, not in the app. The layout is fixed in WMR_Bridge `docs/PROTOCOL.md`, mirrored and explained in this repo's [PROTOCOL.md](PROTOCOL.md):
- `FF12`, notify only, next to the raw `FF11` stream, which keeps working. The two are mutually exclusive (a second enable fails with ATT error 0x80).
- 56-byte version-1 records: hand, buttons, sequence (per hand), ESP32 receive time, `device_ticks` (100 ns, the sensor clock), gyro (rad/s), accel (scale about 10 m/s^2 at rest, not 9.81), temperature, stick, trackpad, trigger, battery. Needs MTU 59 or more.
- Raw IMU is sent, not a quaternion: fusion runs on the phone.
- Planned: FF12 version 2 batching on a new characteristic `FF14` (several records per notification), motivated by bench results showing notification airtime costs controller reports. Not to be used until specified in the firmware docs.
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
- **iOS** (later): `NSBluetoothAlwaysUsageDescription` in Info.plist. iOS controls connection interval, so measure rather than assume.

## Milestones
Status of each is in [STATUS.md](STATUS.md) (1 to 3 done, plus the Capture screen).

1. Scaffold project (`flutter create` into this repo), CI green, `FakeTransport` drives the debug 3D view (no hardware needed).
2. Scan/connect to the ESP32, subscribe, parse packets, show raw values.
3. Debug 3DoF view on real data + stats panel.
4. Latency test screen + CSV export.
5. Write up results; decide Flutter vs native hot path.
6. iOS build, then gamepad-style mapping.

## GitHub and CI
- Repo: `wmr-companion` (public, MIT), default branch `main`. Squash merges.
- `.gitignore`: merge with the one from `flutter create`; keep `*.keystore`, `key.properties`, `local.properties` ignored.
- `.github/workflows/ci.yml` (add in milestone 1): on push/PR, `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug`, upload the APK as an artifact (so any machine can grab a build without an Android SDK).
- Small commits, conventional messages, one milestone per PR.

## Notes for Claude Code
- Keep `CLAUDE.md` in sync with the architecture rules above and the commands (`flutter analyze`, `flutter test`, `flutter run -d <device>`).
- Ask before changing the GATT protocol; the firmware is the source of truth.
- Keep every test hardware-free by using `FakeTransport`.
