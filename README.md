# wmr-companion

Flutter companion app for ESP32 (BTstack) WMR motion controllers. It connects to the [WMR_Bridge](https://github.com/nightcinder/WMR_Bridge) firmware over BLE GATT, fuses controller orientation on the phone (3DoF, Madgwick/Mahony), shows a debug 3D view with link statistics, and records raw captures. Android first, iOS later; the end goal is gamepad-style 3DoF input.

**Status:** milestones 1 to 3 and the Capture screen are done; the decoded-stream (FF12) pipeline and 3D view work on hardware (orientation checked visually, user-reported). Latency/CSV export, iOS and gamepad mapping are not started. Controller-to-ESP32 report loss is the main open problem. See [docs/STATUS.md](docs/STATUS.md) for the current state, hardware results and roadmap, and [docs/PLAN.md](docs/PLAN.md) for architecture.

## What is in the app

- **Connect:** scan for `WMR Bridge`, negotiate MTU, request High connection priority, subscribe to the raw stream (FF11) or the decoded stream (FF12). The two are mutually exclusive on the firmware; the app switches by writing 0 to the active CCC first.
- **Debug:** per-hand 3D orientation, quaternion and Euler readout, packet rate, sequence gaps, tick-derived missing-report count, dt statistics, gyro bias, axis-mapping flip toggles, "Reset orientation". Yaw drifts without a magnetometer.
- **Capture:** guided raw capture from FF11 in the same file format as the firmware's `tools/capture_ble.py`, shareable from the phone. See [docs/CAPTURE.md](docs/CAPTURE.md).
- A fake bridge (raw and decoded) drives the UI and tests without hardware.

## Repo layout

| Path | Contents |
| --- | --- |
| `lib/ble/` | `BleTransport` interface, `universal_ble` implementation, fake transport and fake bridge |
| `lib/protocol/` | GATT identifiers, FF11 fragment reassembler, FF12 record parser (pure Dart) |
| `lib/domain/` | Tick timing, gyro bias, axis mapping, per-hand pipeline, orientation helpers |
| `lib/services/` | `ControllerService`, capture recorder and files |
| `lib/ui/` | Connect, debug and capture screens |
| `packages/wmr_fusion/` | Pure-Dart Madgwick and Mahony filters |
| `docs/` | Status, plan, protocol notes, capture format |

## Build and test

```
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test                      # also: cd packages/wmr_fusion && dart test
flutter build apk --debug
flutter run -d <device>           # BLE needs a physical phone
```

CI runs the same checks and uploads a debug APK. Each CI APK is signed differently, so installing a new one over an old one needs `adb uninstall com.onyxlens.wmr_companion` first.

## License

MIT, see [LICENSE](LICENSE). Third-party packages (universal_ble, vector_math, Flutter) keep their own licenses; Flutter's built-in license page lists them in the app. The firmware repository is under a separate license (derived from BlueKitchen BTstack).
