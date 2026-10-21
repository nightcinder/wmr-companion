# WMR Companion App: Project Plan (for Claude Code)

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
      -> Protocol parser   (pure Dart: bytes -> ControllerPacket)
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
    ble/            # BleTransport, universal_ble impl, fake transport
    protocol/       # GATT UUIDs, packet models, parser
    domain/         # ControllerState, quaternion/euler helpers
    services/       # ControllerService, LatencyService, LogRecorder
    ui/
      scan/         # scan + connect screen
      controller/   # live controller view (buttons, axes, battery)
      debug/        # 3DoF view + stats panel
      latency/      # latency test screen
  test/
  docs/PLAN.md      # this file
  docs/PROTOCOL.md  # must mirror the ESP32 firmware
  .github/workflows/ci.yml
  CLAUDE.md
```

## GATT protocol (PLACEHOLDER: must match firmware)
Claude Code: **read the ESP32 firmware repo to get the real service/characteristic UUIDs and packet layout, then write them to `docs/PROTOCOL.md` and mirror in `lib/protocol/`.** Do not invent UUIDs. Proposed shape if the firmware has no definition yet:

| Characteristic | Props | Payload |
|---|---|---|
| Controller state (one per controller or one with an ID byte) | Notify | `seq:u16, esp_ts_us:u32, quat:4xint16 (Q15) or 4xf32, buttons:u16, axes:..., battery:u8` |
| Latency echo | Write w/o response + Notify | `ping_id:u16` echoed straight back |
| Config (optional) | Read/Write | rate, calibration command |

Little-endian. Keep the packet under the negotiated MTU minus 3.

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

## Latency test screen
1. **One-way jitter**: from the notification stream above. Never compare ESP32 timestamps to the phone clock (not synced); use only inter-arrival deltas and the sequence counter.
2. **Round trip**: write `ping_id` to the echo characteristic, time until the echo notification returns, report p50/p99/max over N=1000 pings.
3. Run at several ESP32 rates (e.g. 50/100/200 Hz) and show a comparison table.
4. Export results as JSON/CSV for the write-up. If p99 is bad, we add a bare-Kotlin `BluetoothGattCallback` baseline to separate plugin overhead from radio/connection-parameter effects.

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
1. Scaffold project (`flutter create` into this repo), CI green, `FakeTransport` drives the debug 3D view (no hardware needed).
2. Scan/connect to the ESP32, subscribe, parse packets, show raw values.
3. Debug 3DoF view on real data + stats panel.
4. Latency test screen + CSV export.
5. Write up results; decide Flutter vs native hot path.
6. iOS build, then gamepad-style mapping.

## GitHub and CI
- Repo: `wmr-companion` (private until it has a README and a license decision), default branch `main`.
- `.gitignore`: merge with the one from `flutter create`; keep `*.keystore`, `key.properties`, `local.properties` ignored.
- `.github/workflows/ci.yml` (add in milestone 1): on push/PR, `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug`, upload the APK as an artifact (so any machine can grab a build without an Android SDK).
- Small commits, conventional messages, one milestone per PR.

## Notes for Claude Code
- Keep `CLAUDE.md` in sync with the architecture rules above and the commands (`flutter analyze`, `flutter test`, `flutter run -d <device>`).
- Ask before changing the GATT protocol; the firmware is the source of truth.
- Keep every test hardware-free by using `FakeTransport`.
