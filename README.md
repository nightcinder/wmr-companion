# wmr-companion

Flutter companion app for ESP32 (BTstack) WMR motion controllers. It connects to the [WMR_Bridge](https://github.com/nightcinder/WMR_Bridge) firmware over BLE GATT, fuses controller orientation on the phone (3DoF, Madgwick/Mahony), shows a debug 3D view with link statistics, and records raw captures. Android first, iOS later; the end goal is gamepad-style 3DoF input.

**Status (v0.2.0):** milestones 1 to 4 and the Capture screen are done and used on hardware (user-reported): the decoded-stream pipeline (FF12, and FF14 batches as the default) and 3D view, the controller config read over FF13 with calibration decoded, and the latency screen with the FF15 round trip (first run: 479 of 479 pings, p50 40.8 ms). An in-app gamepad mapping layer and a Bluetooth HID output ([docs/GAMEPAD.md](docs/GAMEPAD.md)) are built but not run on hardware; iOS is not started. Controller-to-ESP32 report loss (about 19 % per controller with both connected) is the main open problem. Start with [HANDOFF.md](HANDOFF.md), then [docs/STATUS.md](docs/STATUS.md) for the state, hardware results and roadmap, and [docs/PLAN.md](docs/PLAN.md) for architecture.

## What is in the app

- **Connect:** scan for `WMR Bridge`, negotiate MTU, request High connection priority, subscribe to the raw stream (FF11), the decoded stream (FF12) or the batched decoded stream (FF14, the default). They are mutually exclusive on the firmware; the app switches by writing 0 to the active CCC first. The app requests MTU 517 on every connect.
- **Debug:** per-hand 3D orientation, quaternion and Euler readout, packet rate, sequence gaps, tick-derived missing-report count, dt statistics, gyro bias, axis-mapping flip toggles, "Reset orientation". Yaw drifts without a magnetometer.
- **Debug > Read config:** reads each controller's config block over FF13 (CRC-checked) and decodes the gyro and accelerometer calibration. Needs Monado's key table, which is fetched, never committed: `dart run tool/fetch_wmr_config_key.dart` (CI does it for the debug APK). See [docs/PROTOCOL.md](docs/PROTOCOL.md) and [HANDOFF.md](HANDOFF.md).
- **Latency:** inter-arrival, sequence gaps, tick-based loss and the FF15 echo round trip, with CSV and JSON export ([docs/LATENCY.md](docs/LATENCY.md)).
- **Gamepad:** mapping of both controllers to one gamepad, settings saved to the app documents directory, and an optional Bluetooth HID output ([docs/GAMEPAD.md](docs/GAMEPAD.md)); not run on hardware.
- **Capture:** guided raw capture from FF11 in the same file format as the firmware's `tools/capture_ble.py`, shareable from the phone. See [docs/CAPTURE.md](docs/CAPTURE.md).
- A fake bridge (raw and decoded) drives the UI and tests without hardware.

## Repo layout

| Path | Contents |
| --- | --- |
| `lib/ble/` | `BleTransport` interface, `universal_ble` implementation, fake transport and fake bridge |
| `lib/protocol/` | GATT identifiers, FF11 fragment reassembler, FF12 record parser (pure Dart) |
| `lib/domain/` | Tick timing, gyro bias, axis mapping, per-hand pipeline, orientation helpers |
| `lib/services/` | `ControllerService`, capture recorder and files |
| `lib/ui/` | Connect, debug, capture, latency and gamepad screens |
| `lib/hid/` | Bluetooth HID gamepad output |
| `packages/wmr_fusion/` | Pure-Dart Madgwick and Mahony filters |
| `docs/` | Status, plan, protocol notes, capture, latency, gamepad, camera research; [LIBRARY.md](docs/LIBRARY.md) frames the reusable Flutter package split |
| `HANDOFF.md` | Rules, environment, state, not-yet-run list, cleanup list |

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
