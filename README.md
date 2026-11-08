# wmr-companion

Flutter companion app for ESP32 (BTstack) and Linux/Raspberry Pi (Wi-Fi) WMR motion controllers. It connects to the [WMR_Bridge](https://github.com/nightcinder/WMR_Bridge) firmware over BLE GATT or to the Linux/Pi bridge over a WebSocket on Wi-Fi. It fuses controller orientation on the phone (3DoF, Madgwick/Mahony), shows a debug 3D view with link statistics, and records raw captures. The end goal is gamepad-style 3DoF input. The pipeline is extracted into twelve packages that other apps can import in-process on **Android and iOS** (publish-ready, including the `wmr_tracking` 6DoF framework) ([docs/LIBRARY.md](docs/LIBRARY.md); [packages/wmr_companion](packages/wmr_companion/README.md), [packages/wmr_ble](packages/wmr_ble/README.md) and [packages/wmr_ws](packages/wmr_ws/README.md)); the app is the reference consumer. A native Swift framework (`packages/WMRCompanionKit`) covers iOS 18+, macOS 12+ and visionOS 1+.

**Status (v0.3.17, 2026-11-06):** the latest tagged release is the signed unified Android release APK (`wmr-companion-0.3.17-unified-arm64-v8a.apk`). CI built it from commit `e431a39`. v0.3.17 adds report-only Semgrep, gitleaks and Dependabot scans (ONY-890). It also adds the 6-run pose-filter corpus for the ONY-501 addendum (ONY-502).

v0.3.16 detects Android XR before USB IDs (ONY-879). It also stops the vendor Unity player from starting on an Android XR host. v0.3.15 documents the 6-run pose capture protocol and cuts the guided bench to it (ONY-869 / ONY-871).

v0.3.14 shipped on `unity-export-1.4`. That export starts VITURE's input subsystem, so 6DoF head pose reaches the player camera (ONY-856). The Bench screen shows the live hand-joint skeleton and a 6DoF head-pose travel indicator (ONY-857). A Neckband with hand tracking selects 6DoF automatically after the startup tracking probe settles. The stereo side-by-side panes follow live 6DoF head motion, with a recenter action and a zero-pose fallback (ONY-858).

v0.3.13 shipped on `unity-export-1.3`. Embedded VITURE UaaL is hand-only, so the display provider cannot take over the Flutter host activity. The unshaded marker cubes are gone (ONY-840). Unity and vendor player activities are no longer exported (ONY-842).

One `unified` flavor links a single shared `unityLibrary`. It carries the VITURE 0.9.0 and XREAL 3.1.0 SDKs and selects the vendor at runtime. v0.3.12 was the first release on `unity-export-1.2`. It pins the Unity player to OpenGL ES 3, so VITURE's display provider does not take the Vulkan stop path that crashed the guided bench on a Pro Neckband (ONY-802). Its loader gate starts VITURE's hand and input subsystems on a player that is not GLES3. The display subsystem stays stopped. Its hosted Unity view does not take D-pad focus, so the Flutter UI keeps it. Volume Up and Volume Down move focus. Holding Volume Down selects, and holding Volume Up goes back, with or without headgaze.

The release keeps the 0.3.11 automatic glasses detection on startup. The manual tracking-source dropdown is removed (ONY-777). It also keeps the XREAL cold-start fix, which defers `UnitySendMessage` until the Unity player is hosted, and the R8 keep rules for the JNI callbacks (ONY-776). The owner approved SDK redistribution and supplied the export (ONY-354). The release APK is signed with the project key and updates in place. Debug builds carry the `.debug` package suffix since 0.3.3, so they no longer collide with the release APK. A phone that holds a pre-0.3.3 debug or locally signed build must be uninstalled once first (`docs/RELEASE_SIGNING.md`).

Launch-crash fixes since 0.3.0 kept the XREAL display stub in the release dex. They defer the glasses model check to the Unity start handshake. They also make VITURE start when the glasses model is not reported, because VITURE requires stereo 3D. Per-vendor build flavors were dropped, so `unified` is the only published flavor.

The core pipeline is built. It uses FF12 and FF14 batches as the default stream. The 3D view, the controller configuration read over FF13 with calibration decoded, the latency screen with the FF15 round trip, the Capture screen, the package split, and the guided bench with 6DoF pose capture are also built. The first latency run answered 479 of 479 pings at p50 40.8 ms. The hardware results are user-reported. The v0.3.17 APK has only passed CI and export checks. The Debug screen shows the connected bridge's FF16 firmware string and FF11–FF17 feature bits (GitHub #107). An in-app gamepad mapping layer and a Bluetooth HID output ([docs/GAMEPAD.md](docs/GAMEPAD.md)) are built but not run on hardware.

Android and iOS are both in v1 scope (iOS 18 floor). There is still no iOS device run. The Dart packages are at `0.3.0` and publish-ready. CI runs `dart pub publish --dry-run` for each. They are not on pub.dev (owner hold). Controller-to-ESP32 report loss of about 19 % per controller with both connected is the main open problem. A headset head/hand tracking seam for 6DoF is in `packages/wmr_tracking` ([docs/TRACKING.md](docs/TRACKING.md)). It is desk research plus a unit-tested framework, and no vendor adapter has run on hardware. Start with [HANDOFF.md](HANDOFF.md), then [docs/STATUS.md](docs/STATUS.md) for the state, hardware results and roadmap, and [docs/PLAN.md](docs/PLAN.md) for architecture.

**Release:** [`v0.3.17`](https://github.com/nightcinder/wmr-companion/releases/tag/v0.3.17) carries `wmr-companion-0.3.17-unified-arm64-v8a.apk` (430,490,614 B, SHA-256 `1efe4c1f2e9c8ca885f9b698b6415a3eab2f817fe3cd5e29ab5541baadd03d78`). For the signed build, debug-build `.debug` package suffix, and uninstall recovery for pre-0.3.3 builds, see [docs/RELEASE_SIGNING.md](docs/RELEASE_SIGNING.md). Build matrix and the unified export installer: [docs/tracking/BUILDS.md](docs/tracking/BUILDS.md) and [apps/wmr_companion_app/android/unity/README.md](apps/wmr_companion_app/android/unity/README.md).

## What is in the app

- **Connect:** scan for `WMR Bridge` over BLE, or switch link to Wi-Fi and connect to a Linux/Raspberry Pi bridge daemon via `host:port` (optional token auth and TLS). On BLE, negotiate MTU, request High connection priority, and subscribe to the raw stream (FF11), the decoded stream (FF12) or the batched decoded stream (FF14, the default). On Wi-Fi, the daemon serves the same streams over WebSocket subprotocol `wmr-wifi-v1`. Streams are mutually exclusive; the app switches by writing 0 to the active CCC or sending an unsubscribe first. On BLE the app requests MTU 517 on every connect. Wi-Fi bridge streaming is host-tested/loopback-only until the Pi hardware sitting.

  **Security posture (0.3).** The BLE bridge now requires LE Secure Connections with bonding (firmware 0.3.0): data characteristics and their CCCs are encrypted, a security request is sent on connect, and an unbonded central is disconnected after the 30 s pair window. Pairing is Just Works (no display/keypad), so it is encrypted but not MITM-protected; pair in a private place. FF16 (firmware version) stays readable before pairing. The Pi daemon still serves plaintext `ws://` with a shared bearer token (required for a non-loopback bind) and no built-in TLS, so terminate TLS externally or use a trusted WPA2/WPA3 LAN. Flash encryption and secure boot remain off. See [Security posture for 0.3](docs/STATUS.md#security-posture-for-03).

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
| `packages/wmr_tracking_dispatch/` | Native pre-Unity glasses vendor detection, the Dart `TrackingSourceSelector` and one shared `SharedUnityRuntime` for VITURE/XREAL ([docs/GLASSES_DETECTION.md](docs/GLASSES_DETECTION.md)) |
| `packages/wmr_tracking_unity/` | One Unity 6000.0 project and `WmrTrackingRelay` for both vendors; its exported `unityLibrary` is what the `unified` flavor links ([README](packages/wmr_tracking_unity/README.md)) |
| `packages/wmr_tracking_viture/` | Default-off VITURE Pro Neckband Unity UaaL head and 26-joint hand relay source; Kotlin/Dart host-tested, Unity 6000.0.27f1 / VITURE XR SDK v0.9.0 (`Viture.XR.VitureXR`) is an external SDK gate ([docs/TRACKING.md](docs/TRACKING.md)) |
| `packages/wmr_tracking_xreal/` | Default-off XREAL Air 2 Ultra Unity UaaL head and 26-joint hand relay source; Kotlin/Dart host-tested, Unity 2021.3+/6000.0 / XREAL SDK 3.x is an external SDK gate ([docs/TRACKING.md](docs/TRACKING.md)) |
| `packages/WMRCompanionKit/` | Native Swift framework: iOS 18+, macOS 12+, visionOS 1+ CoreBluetooth & parsers |
| `tool/` | Monado config-key fetch, `fresh_app_check.sh`, and the iOS probe app |
| `docs/` | Status, plan, protocol notes, capture, latency, gamepad, iOS, publishing, camera and headset-tracking research; [LIBRARY.md](docs/LIBRARY.md) frames the reusable package split |
| `HANDOFF.md` | Rules, environment, state, not-yet-run list, cleanup list |

## Build and test

```
cd apps/wmr_companion_app
flutter pub get
dart format --set-exit-if-changed .
flutter analyze
flutter test
tool/build_flavor.sh base          # flavors: base, unified; only unified ships
flutter run --flavor base -d <device>   # BLE needs a physical phone

# Unified APK: install the owner's unityLibrary export, then build
tool/install_unity_export.sh unified path/to/unityLibrary.zip
tool/build_flavor.sh unified --debug
```

From the repo root, the package suites are: `cd packages/wmr_core && dart test`; `cd packages/wmr_companion && dart test`; `cd packages/wmr_ble && flutter test`; `cd packages/wmr_ws && dart test`; `cd packages/wmr_companion_ui && flutter test`; `cd packages/wmr_companion_hid_android && flutter test`; `cd packages/wmr_fusion && dart test`; `cd packages/wmr_tracking && dart test`; `cd packages/wmr_tracking_dispatch && flutter test`; `cd packages/wmr_tracking_android_xr && flutter test`; `cd packages/wmr_tracking_viture && flutter test`; `cd packages/wmr_tracking_xreal && flutter test`; `cd example && flutter test`. On macOS, `cd packages/WMRCompanionKit && swift test` covers the Swift framework and `cd apps/wmr_visionos_app && swift build && swift test` covers the visionOS package.

CI also runs `dart analyze`/`flutter analyze` in each package, a `dart pub publish --dry-run` for all twelve packages, and `tool/fresh_app_check.sh`, then uploads a debug APK. Debug builds use the `com.onyxlens.wmr_companion.debug` package, so they never block the `com.onyxlens.wmr_companion` release APK from GitHub; each CI debug APK is still signed differently from the last, so a debug APK only replaces another after `adb uninstall com.onyxlens.wmr_companion.debug` (which clears app data). Release APKs from the project key update each other in place -- see `docs/RELEASE_SIGNING.md`.

## License

MIT, see [LICENSE](LICENSE). Third-party packages (universal_ble, vector_math, Flutter) keep their own licenses; Flutter's built-in license page lists them in the app. The firmware repository is under a separate license (derived from BlueKitchen BTstack).
