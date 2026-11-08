# iOS Companion App Framework

This document describes the iOS architecture, CoreBluetooth GATT implementation, and the standalone Swift framework (`WMRCompanionKit`) for the WMR Companion application.

## 1. Overview & Architecture

The iOS companion framework enables Apple devices (iPhone, iPad, visionOS) to communicate with the [WMR_Bridge](https://github.com/nightcinder/WMR_Bridge) ESP32 firmware over Bluetooth Low Energy (BLE) GATT.

```
+-----------------------------------------------------------------------------------+
|                            Applications / Consumers                               |
|   - Flutter Companion App (via platform channels / universal_ble)                |
|   - Native iOS Diagnostic Probe App (tool/ios_probe/WMRCompanionProbe)            |
|   - VisionOS / RealityKit 3DoF/6DoF Controller Clients                           |
+-----------------------------------------------------------------------------------+
                                        |
+-----------------------------------------------------------------------------------+
|                        WMRCompanionKit (Swift Package)                            |
|   +-----------------------+  +--------------------------+  +-------------------+  |
|   |  WMRBleCentralManager |  |  WMRFragmentReassembler  |  | WMRMadgwickFilter |  |
|   |   (CoreBluetooth)     |  |   (FF11 HID Reports)     |  |  WMRMahonyFilter  |  |
|   +-----------------------+  +--------------------------+  +-------------------+  |
|   |   WMRBridgeSession    |  |    WMRDecodedRecord      |  |  WMRHandPipeline  |  |
|   | (Single/Dual Bridge)  |  |    WMRDecodedBatch       |  |  (100ns Ticks dt) |  |
|   +-----------------------+  +--------------------------+  +-------------------+  |
|   |   WMREcho / Latency   |  |   WMRConfigDecoder       |  | WMRCompanionClient|  |
|   |  (FF15 Round-Trip)    |  |   (FF13 CRC32 + XOR)     |  | (Combine / Async) |  |
|   +-----------------------+  +--------------------------+  +-------------------+  |
+-----------------------------------------------------------------------------------+
                                        |
+-----------------------------------------------------------------------------------+
|                     Apple CoreBluetooth Framework (iOS / visionOS)                 |
+-----------------------------------------------------------------------------------+
                                        |  (BLE GATT Service 0xFF10)
                                        v
+-----------------------------------------------------------------------------------+
|                          ESP32 WMR_Bridge Firmware                                |
|        (BTstack Classic HID Host to WMR Controllers -> BLE GATT Server)           |
+-----------------------------------------------------------------------------------+
```

## 2. CoreBluetooth Nuances on iOS

Building a low-latency companion client on iOS requires handling several CoreBluetooth-specific platform behaviors:

1. **MTU Negotiation**:
   - Unlike Android, iOS applications cannot explicitly request a target ATT MTU (such as MTU 517).
   - CoreBluetooth automatically negotiates MTU during initial service and characteristic discovery (typically 185 bytes on older devices, up to 517 bytes on modern hardware).
   - `WMRCompanionKit` queries `peripheral.maximumWriteValueLength(for: .withoutResponse)` and adjusts packet chunking dynamically.
2. **Connection Parameters & Interval**:
   - iOS controls connection intervals autonomously through its Apple Bluetooth Accessory Design Guidelines (typically 15 ms to 30 ms). The app cannot directly request `CONNECTION_PRIORITY_HIGH`.
   - Latency tests (`WMREcho`) measure actual observed round-trip times and quantize them against the underlying connection interval.
3. **Stream Mutual Exclusion (ATT Error 0x80)**:
   - The bridge enforces mutual exclusion between `FF11` (raw HID), `FF12` (single decoded), and `FF14` (batched decoded).
   - Subscribing to one while another is active returns ATT error `0x80` (`attErrorOtherStreamActive`).
   - `WMRBleCentralManager` strictly handles this transition: whenever changing stream modes, it writes `0x0000` to disable the active CCC before enabling the target stream's CCC.
4. **Nanosecond Arrival Stamping**:
   - To separate BLE delivery and OS queueing jitter from application processing, `WMRBleCentralManager` captures `DispatchTime.now().uptimeNanoseconds` at the very first line of `peripheral(_:didUpdateValueFor:error:)`.

## 3. `WMRCompanionKit` Swift Package

The core framework is implemented in `packages/WMRCompanionKit` as a modular Swift Package supporting iOS 18.0+, macOS 12.0+, and visionOS 1.0+.

### Components

- **`Protocol/`**:
  - `WMRFragmentReassembler`: Reassembles 12-byte header FF11 fragments (magic `0x52`, per-hand slots, modular sequence wrap).
  - `WMRDecodedRecord`: Parses 56-byte version-1 decoded records (gyro rad/s, accel m/s^2, 100 ns sensor clock ticks, temperature, stick, trackpad, trigger, buttons).
  - `WMRDecodedBatch`: Parses batched version-2 decoded notifications (1 to 9 records).
  - `WMREcho`: Encodes 4-byte ping requests and parses 20-byte pong answers (ping ID, client send timestamp, ESP32 turnaround µs, queue depth).
  - `WMRConfigBlock` & `WMRConfigDecoder`: CRC-32 (IEEE 802.3), Monado XOR key de-obfuscation, and JSON sensor calibration extraction.
  - `WMRFirmwareVersion`: Decodes the FF16 31-byte UTF-8 firmware version and derives the FF11–FF17 feature matrix from the GATT table.
  - `WMRControllerControl`: Parses the FF17 20-byte controller status v2 and encodes the 1–2 byte discover/connect/disconnect/forget commands.
- **`Fusion/`**:
  - `WMRMadgwickFilter` & `WMRMahonyFilter`: Pure Swift 6-axis orientation fusion.
  - `WMRHandPipeline`: Integrates sensor samples using true $dt$ computed from 100 ns sensor ticks, applies axis mapping, and tracks sequence gaps and tick-based packet loss %.
- **`BLE/`**:
  - `WMRBleCentralManager`: CoreBluetooth peripheral discovery, MTU inspection, and safe stream switching.
  - `WMRBridgeSession`: Single-bridge session managing Left and Right controller pipelines and echo round-trip testing.
  - `WMRMultiBridgeSession`: Dual-bridge coordinator for concurrent zero-loss tracking.
- **`Client/`**:
  - `WMRCompanionClient`: Modern Combine and async/await facade for application UI layers.

## 4. Native iOS Diagnostic Probe (`tool/ios_probe`)

A native SwiftUI application is provided in `tool/ios_probe/` to serve as a latency baseline and diagnostic probe (Milestone 7.1):
- Connects directly via CoreBluetooth with zero platform channel or Dart runtime overhead.
- Supports selectable stream modes (`None`, `FF11`, `FF12`, `FF14`).
- Real-time FF15 echo round-trip measurement with p50, p95, p99 percentiles and turnaround time readout.
- Exports standardized `wmr-latency` v2 JSON summaries and per-ping CSV files via the iOS system share sheet.

## 5. Native visionOS Companion App (`apps/wmr_visionos_app`)

`apps/wmr_visionos_app` is a Swift package. It links `packages/WMRCompanionKit` and targets visionOS 1, iOS 18, and macOS 14.

Architecture:

- `WMRVisionOSCore` holds `VisionOSTrackingTypes`, `VisionOSTrackingProvider`, and `VisionOSCompanionViewModel`.
- `VisionOSTrackingTypes` defines head, hand, and controller pose snapshots. `VisionOSControllerPoseComposer` takes translation from the tracked wrist and orientation from the bridge's fused 3DoF state.
- `VisionOSTrackingProvider` is a protocol with a simulated implementation. On visionOS, `ARKitVisionOSTrackingProvider` wraps `ARKitSession` with `WorldTrackingProvider` and `HandTrackingProvider`.
- `VisionOSCompanionViewModel` is `@MainActor`. It joins `WMRControllerState` updates with the latest wrist poses and publishes per-hand 6DoF controller poses.
- `WMRVisionOSApp` is the SwiftUI `App` scene. It contains `CompanionDashboardView` for BLE scan and connect, stream selection, ping telemetry, and controller status. It also contains `ControllerRealityView` for the 6DoF `ImmersiveSpace`. RealityKit compiles under `#if os(visionOS)`.
- `apps/wmr_visionos_app/Sources/WMRVisionOSApp/Resources/Info.plist` declares the four privacy keys listed below.

ARKit plus BLE 6DoF fusion:

The bridge reports a 3DoF orientation from its IMU over BLE. ARKit reports where the wrist is. The view model stores the latest controller state per hand. When a wrist pose arrives, it composes a 6DoF pose. The wrist supplies translation. The bridge supplies orientation. `VisionOSControllerPoseComposer` adds a fixed grip offset of about 8 cm in front of the wrist. The result is one 6DoF controller pose per hand.

Required Info.plist privacy keys:

- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription`
- `NSHandsTrackingUsageDescription`
- `NSWorldSensingUsageDescription`

Three keys prompt the user: Bluetooth always, hand tracking, and world sensing. `NSBluetoothPeripheralUsageDescription` is the legacy key and produces no prompt; it remains for back-compat. The text in `apps/wmr_visionos_app/Sources/WMRVisionOSApp/Resources/Info.plist` states why the app needs the access.

Simulator and hardware:

- The package builds and tests on macOS. Run `cd apps/wmr_visionos_app && swift build && swift test`.
- The ARKit and RealityKit paths compile only on visionOS. macOS tests use the simulated provider.
- ARKit hand tracking does not run in the visionOS Simulator. A physical Apple Vision Pro is required to exercise 6DoF composition.
- The shipped provider does not check `WorldTrackingProvider.isSupported`. `ARKitSession.run` throws `ARKitError.providerNotSupported` when a provider is unsupported. Handle that error when starting tracking.
- BLE needs a physical WMR Bridge. The Simulator cannot reach it.

No-Unity boundary:

The visionOS target is native Swift. It does not link Unity and has no Unity runtime. It does not use the Android `base` or `unified` flavors or `--dart-define` flags. The Flutter app and the Android XR path keep their own Unity gates.

Building and signing in Xcode:

The package has no Xcode project. To run it on a device, wrap it in an Xcode app target.

1. Install Xcode with the visionOS SDK.
2. Open the package in Xcode with `open apps/wmr_visionos_app/Package.swift`.
3. Create a visionOS app target, or add the package to an existing visionOS app.
4. Set a unique bundle identifier for the target.
5. Open Signing & Capabilities and select your team. Turn on automatic signing for development.
6. Set the deployment target to visionOS 1.0 or later.
7. Copy the four privacy keys from `apps/wmr_visionos_app/Sources/WMRVisionOSApp/Resources/Info.plist` into the app target's Info.plist.
8. Add the local package and link `WMRVisionOSApp`.
9. Select an Apple Vision Pro device or the visionOS Simulator as the destination. Build and run.
10. On the device, accept the Bluetooth, hand tracking, and world sensing prompts.
11. For distribution, use an Apple Developer Program account. Archive the app with a distribution certificate and a matching provisioning profile. visionOS uses Apple signing, not the Android keystore.

CI:

The `ios` job in `.github/workflows/ci.yml` builds and tests the package on `macos-latest`.

## 6. Flutter iOS Integration & CI

- `apps/wmr_companion_app/ios/Runner.xcodeproj`: Links the generated `Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage`, and every iOS plugin (`universal_ble`, `device_info_plus`, `package_info_plus`, `share_plus`) ships its own `Package.swift`. The project is therefore Swift-Package-only: there is no `Podfile` (and `example/ios` follows the same layout), so a build never runs CocoaPods. If a pod-only plugin is ever added, Flutter regenerates a standard `Podfile`; restore the iOS 18.0 `IPHONEOS_DEPLOYMENT_TARGET` pin in its `post_install` hook.
- `apps/wmr_companion_app/ios/Runner/Info.plist`: Includes `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`, and `UIBackgroundModes` (`bluetooth-central`).
- `.github/workflows/ci.yml`: Includes a dedicated `ios` job running on `macos-latest` that validates `WMRCompanionKit` unit tests (`swift test`), the `apps/wmr_visionos_app` package build and tests (`swift build` and `swift test`), and Flutter iOS project build configuration (`flutter build ios --config-only --no-codesign`).
