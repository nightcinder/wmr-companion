# wmr-companion

Flutter companion app for ESP32 (BTstack) and Linux/Raspberry Pi (Wi-Fi) WMR motion controllers. It connects to the [WMR_Bridge](https://github.com/nightcinder/WMR_Bridge) firmware over BLE GATT or to the Linux/Pi bridge over a WebSocket on Wi-Fi. It fuses controller orientation on the phone (3DoF, Madgwick/Mahony), shows a debug 3D view with link statistics, and records raw captures. The end goal is gamepad-style 3DoF input.

The pipeline is split into twelve packages that other apps can import on Android and iOS. The app is the reference consumer. A native Swift framework covers iOS 18+, macOS 12+, and visionOS 1+.

Current full release: v0.3.24 (signed unified Android APK). Pre-release: v0.3.25-rc.1. The in-app bridge upgrade needs a WMR_Bridge build with `upgradeCapable`. See [docs/STATUS.md](docs/STATUS.md) for state, hardware results, and roadmap, and [docs/PLAN.md](docs/PLAN.md) for architecture.

## What is in the app

- **Connect:** scan for `WMR Bridge` over BLE, scan the LAN for a Pi bridge, or connect to a Linux/Pi bridge daemon over Wi-Fi. On BLE, negotiate MTU, request high connection priority, and subscribe to the raw (FF11), decoded (FF12), or batched (FF14) stream. On Wi-Fi, the daemon serves the same streams over WebSocket. Streams are mutually exclusive.
- **Debug:** per-hand 3D orientation, quaternion and Euler readout, packet rate, sequence gaps, missing-report count, dt statistics, gyro bias, axis-mapping toggles, and "Reset orientation". Yaw drifts without a magnetometer.
- **Latency:** inter-arrival, sequence gaps, tick-based loss, and the FF15 echo round trip, with CSV and JSON export.
- **Gamepad:** mapping of both controllers to one gamepad, settings saved to the app documents directory, and optional Bluetooth HID output. Not run on hardware. At the library layer, `wmr_core` and `wmr_companion` export an experimental DroidDeck v0 6DoF Unix domain socket transport sink (#300, #301), but the app UI does not construct it yet.
- **Capture:** guided raw capture from FF11 in the same file format as the firmware tool, shareable from the phone. The diagnostic bundle includes a device environment snapshot for URXR One day-one checks.

A fake bridge (raw and decoded) drives tests without hardware. The app only connects to real devices.

## Repo layout

| Path | Contents |
| --- | --- |
| `apps/wmr_companion_app/` | Flutter reference app |
| `packages/` | Twelve Dart packages plus Swift `WMRCompanionKit` |
| `example/` | Minimal Flutter host |
| `docs/` | Status, plan, protocol, capture, latency, gamepad, and tracking notes |
| `HANDOFF.md` | Rules, environment, state, and cleanup list |

## Build and test

```
cd apps/wmr_companion_app
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
```

Package suites and build commands are listed in [HANDOFF.md](HANDOFF.md).

## License

MIT, see [LICENSE](LICENSE). Third-party packages keep their own licenses. The firmware repository is under a separate license (derived from BlueKitchen BTstack).
