# wmr-companion

Flutter companion app for ESP32 (BTstack) and Linux/Raspberry Pi (Wi-Fi) WMR motion controllers. It connects to the [WMR_Bridge](https://github.com/nightcinder/WMR_Bridge) firmware over BLE GATT or to the Linux/Pi bridge over a WebSocket on Wi-Fi, fuses controller orientation on the phone (3DoF, Madgwick/Mahony), shows a debug 3D view with link statistics, and records raw captures. The end goal is gamepad-style 3DoF input. The pipeline is extracted into eleven packages that other apps can import in-process on **Android and iOS** (publish-ready, including the `wmr_tracking` 6DoF framework) ([docs/LIBRARY.md](docs/LIBRARY.md); [packages/wmr_companion](packages/wmr_companion/README.md), [packages/wmr_ble](packages/wmr_ble/README.md) and [packages/wmr_ws](packages/wmr_ws/README.md)); the app is the reference consumer. A native Swift framework (`packages/WMRCompanionKit`) covers iOS 18+, macOS 12+ and visionOS 1+.

**Status (v0.1.0, 2026-10-24):** the core pipeline (FF12, and FF14 batches as the default stream) and 3D view, the controller config read over FF13 with calibration decoded, the latency screen with the FF15 round trip (first run: 479 of 479 pings, p50 40.8 ms), the Capture screen and the package split are built; the hardware results are user-reported. An in-app gamepad mapping layer and a Bluetooth HID output ([docs/GAMEPAD.md](docs/GAMEPAD.md)) are built but not run on hardware. Android and iOS are both in v1 scope (iOS 18 floor; the device gate was waived for `0.1.0`, so iOS is CI-compiled but has no device run). The eleven Dart packages are publish-ready (CI runs `dart pub publish --dry-run` for each) but are not on pub.dev: `0.1.0` is on owner hold. Controller-to-ESP32 report loss (about 19 % per controller with both connected) is the main open problem. A headset head/hand tracking seam for 6DoF is in `packages/wmr_tracking` ([docs/TRACKING.md](docs/TRACKING.md)); it is desk research plus a unit-tested framework, with no vendor adapter run on hardware. Start with [HANDOFF.md](HANDOFF.md), then [docs/STATUS.md](docs/STATUS.md) for the state, hardware results and roadmap, and [docs/PLAN.md](docs/PLAN.md) for architecture.

## What is in the app

- **Connect:** scan for `WMR Bridge` over BLE, or switch link to Wi-Fi and connect to a Linux/Raspberry Pi bridge daemon via `host:port` (optional token auth and TLS). On BLE, negotiate MTU, request High connection priority, and subscribe to the raw stream (FF11), the decoded stream (FF12) or the batched decoded stream (FF14, the default). On Wi-Fi, the daemon serves the same streams over WebSocket subprotocol `wmr-wifi-v1`. Streams are mutually exclusive; the app switches by writing 0 to the active CCC or sending an unsubscribe first. On BLE the app requests MTU 517 on every connect. Wi-Fi bridge streaming is host-tested/loopback-only until the Pi hardware sitting.
- **Debug:** per-hand 3D orientation, quaternion and Euler readout, packet rate, sequence gaps, tick-derived missing-report count, dt statistics, gyro bias, axis-mapping flip toggles, "Reset orientation". Yaw drifts without a magnetometer.
- **Debug > Read config:** reads each controller's config block over FF13 (CRC-checked) and decodes the gyro and accelerometer calibration. Needs Monado's key table, which is fetched, never committed: from `apps/wmr_companion_app`, run `dart run ../../tool/fetch_wmr_config_key.dart` (CI does it for the debug APK). See [docs/PROTOCOL.md](docs/PROTOCOL.md) and [HANDOFF.md](HANDOFF.md).
- **Latency:** inter-arrival, sequence gaps, tick-based loss and the FF15 echo round trip, with CSV and JSON export ([docs/LATENCY.md](docs/LATENCY.md)).
- **Gamepad:** mapping of both controllers to one gamepad, settings saved to the app documents directory, and an optional Bluetooth HID output ([docs/GAMEPAD.md](docs/GAMEPAD.md)); not run on hardware.
- **Capture:** guided raw capture from FF11 in the same file format as the firmware's `tools/capture_ble.py`, shareable from the phone. See [docs/CAPTURE.md](docs/CAPTURE.md).
- A fake bridge (raw and decoded) drives tests without hardware. The app
  itself only connects to real devices.

## Repo layout

| Path | Contents |
| --- | --- |
| `apps/wmr_companion_app/` | Flutter reference app: `lib/`, `test/`, `android/`, `ios/`, `assets/` and its `pubspec.yaml` |
| `apps/wmr_companion_app/lib/services/` | App-side config report, key store and settings wiring |
| `apps/wmr_companion_app/lib/ui/` | Connect, debug, capture, latency and gamepad screens |
| `apps/wmr_companion_app/lib/hid/` | Bluetooth HID gamepad output |
| `packages/wmr_core/` | Pure-Dart protocol, domain, `BleTransport` interface and controller services (no Flutter) |
| `packages/wmr_companion/` | Public facade (`WmrCompanion`) over the pipeline; Android and iOS library path ([README](packages/wmr_companion/README.md)) |
| `packages/wmr_ble/` | `universal_ble` adapter/transport, link status and lifecycle hook ([README](packages/wmr_ble/README.md)) |
| `packages/wmr_ws/` | Pure-Dart WebSocket transport for Linux/Raspberry Pi Wi-Fi bridge daemon behind `BleTransport` seam ([README](packages/wmr_ws/README.md)) |
| `packages/wmr_companion_ui/` | Optional orientation, link, hand-stats and gamepad widgets ([README](packages/wmr_companion_ui/README.md)) |
| `packages/wmr_companion_hid_android/` | Optional Android Bluetooth HID gamepad output ([README](packages/wmr_companion_hid_android/README.md)) |
| `example/` | Minimal Flutter host: one facade, a connect and a gamepad `StreamBuilder` on the fake bridge ([README](example/README.md)) |
| `packages/wmr_fusion/` | Pure-Dart Madgwick and Mahony filters |
| `packages/wmr_tracking/` | Pure-Dart head/hand tracking seam and 6DoF controller fusion, with vendor capability profiles, a One Euro filter, Unity-to-OpenXR conversion and a JSON relay codec (publish-ready; see [docs/TRACKING.md](docs/TRACKING.md)) |
| `packages/wmr_tracking_android_xr/` | Default-off Kotlin Android XR head and 26-joint hand source; compiles against the Jetpack XR SDK 1.0.0, no hardware run yet ([docs/TRACKING.md](docs/TRACKING.md)) |
| `packages/wmr_tracking_viture/` | Default-off VITURE Pro Neckband Unity UaaL head and 26-joint hand relay source; Kotlin/Dart host-tested, Unity 6000.0+ / VITURE SDK v0.7.0 is an external SDK gate ([docs/TRACKING.md](docs/TRACKING.md)) |
| `packages/wmr_tracking_xreal/` | Default-off XREAL Air 2 Ultra Unity UaaL head and 26-joint hand relay source; Kotlin/Dart host-tested, Unity 2021.3+/6000.0 / XREAL SDK 3.x is an external SDK gate ([docs/TRACKING.md](docs/TRACKING.md)) |
| `packages/WMRCompanionKit/` | Native Swift framework: iOS 18+, macOS 12+, visionOS 1+ CoreBluetooth & parsers |
| `tool/` | Monado config-key fetch, `fresh_app_check.sh`, and the native Android GATT / iOS probe apps |
| `docs/` | Status, plan, protocol notes, capture, latency, gamepad, iOS, publishing, camera and headset-tracking research; [LIBRARY.md](docs/LIBRARY.md) frames the reusable package split |
| `HANDOFF.md` | Rules, environment, state, not-yet-run list, cleanup list |

## Build and test

```
cd apps/wmr_companion_app
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
tool/build_flavor.sh base          # flavors: base, viture, xreal
flutter run --flavor base -d <device>   # BLE needs a physical phone
```

From the repo root, the package suites are: `cd packages/wmr_core && dart test`; `cd packages/wmr_companion && dart test`; `cd packages/wmr_ble && flutter test`; `cd packages/wmr_ws && dart test`; `cd packages/wmr_companion_ui && flutter test`; `cd packages/wmr_companion_hid_android && flutter test`; `cd packages/wmr_fusion && dart test`; `cd packages/wmr_tracking && dart test`; `cd packages/wmr_tracking_android_xr && flutter test`; `cd packages/wmr_tracking_viture && flutter test`; `cd packages/wmr_tracking_xreal && flutter test`; `cd example && flutter test`. On macOS, `cd packages/WMRCompanionKit && swift test` covers the Swift framework.

CI also runs `dart analyze`/`flutter analyze` in each package, a `dart pub publish --dry-run` for all eleven packages, and `tool/fresh_app_check.sh`, then uploads a debug APK. The `v0.1.0` GitHub release carries `wmr-companion-0.1.0-debug.apk` and the GATT probe APK. Each CI APK is signed differently, so installing a new one over an old one needs `adb uninstall com.onyxlens.wmr_companion` first.

## License

MIT, see [LICENSE](LICENSE). Third-party packages (universal_ble, vector_math, Flutter) keep their own licenses; Flutter's built-in license page lists them in the app. The firmware repository is under a separate license (derived from BlueKitchen BTstack).
