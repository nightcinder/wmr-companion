# iOS Companion App Framework

This document outlines the iOS architecture, CoreBluetooth GATT implementation, and the standalone Swift framework (`WMRCompanionKit`) for the WMR Companion application.

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

## 5. Flutter iOS Integration & CI

- `apps/wmr_companion_app/ios/Podfile`: Configured for iOS 18.0+, integrating Flutter plugins with modular headers.
- `apps/wmr_companion_app/ios/Runner/Info.plist`: Includes `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`, and `UIBackgroundModes` (`bluetooth-central`).
- `.github/workflows/ci.yml`: Includes a dedicated `ios` job running on `macos-latest` that validates `WMRCompanionKit` unit tests (`swift test`) and Flutter iOS project build configuration (`flutter build ios --config-only --no-codesign`).
