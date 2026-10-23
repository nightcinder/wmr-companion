# WMRCompanionKit

A pure Swift framework for building iOS, macOS, and visionOS companion applications that connect to the [WMR_Bridge](https://github.com/nightcinder/WMR_Bridge) ESP32 firmware over BLE GATT.

`WMRCompanionKit` provides the core transport, protocol decoding, and orientation fusion pipelines for Windows Mixed Reality motion controllers without requiring Flutter or third-party dependencies.

## Features

- **CoreBluetooth Central**: Scans, connects, and manages GATT services and characteristics (`0xFF10` primary service).
- **Protocol Decoding**:
  - `FF11`: Reassembles fragmented raw HID reports (magic `0x52`, sequence wrapping, chunk bounds checking).
  - `FF12`: Parses 56-byte decoded records (version 1, button bitmask, 100 ns sensor clock, gyro rad/s, accel m/s^2, trigger, stick, trackpad, battery).
  - `FF14`: Parses batched decoded records (version 2, up to 9 records per notification at MTU 517).
  - `FF15`: Round-trip echo ping/pong latency measurement (version 1, client timestamp, ESP32 turnaround us, queue depth).
  - `FF13`: Reads controller config blobs, validates CRC-32 (IEEE 802.3), de-obfuscates with Monado key table, and parses sensor calibration (mixing matrix, bias, rotation).
- **Stream Exclusion Engine**: Enforces the bridge's mutual exclusion rule across FF11, FF12, and FF14 (disables active CCC before enabling target stream; handles ATT error `0x80`).
- **Orientation Fusion**: Pure Swift implementations of **Madgwick** and **Mahony** AHRS algorithms running at ~200 Hz with timestep $dt$ derived from 100 ns sensor hardware ticks.
- **Multi-Bridge Coordination**: Seamlessly manages concurrent connections to two independent ESP32 bridges (e.g., Left Bridge and Right Bridge) to eliminate upstream Classic Bluetooth radio contention.
- **Reactive APIs**: Exposes high-level controller state updates, link quality statistics, and latency events via Swift Combine Publishers and `AsyncStream`.

## Supported Platforms

- iOS 18.0+
- macOS 12.0+
- visionOS 1.0+

## Swift Package Manager

Add `WMRCompanionKit` to your `Package.swift`:

```swift
dependencies: [
    .package(path: "packages/WMRCompanionKit")
]
```

Or in Xcode: **File > Add Package Dependencies...** and add the local package path.

## Quick Start

### 1. Scan and Connect

```swift
import WMRCompanionKit

let client = WMRCompanionClient.shared

// Observe discovered bridges
client.$discoveredBridges
    .sink { bridges in
        if let bridge = bridges.first {
            client.connect(to: bridge)
        }
    }
    .store(in: &cancellables)

client.startScanning()
```

### 2. Stream Orientation and Inputs

```swift
// Choose stream mode (FF14 batched recommended)
client.setStreamMode(.batchedFF14)

// Listen to Left Controller updates
client.leftControllerPublisher
    .sink { state in
        guard state.isConnected else { return }
        print("Left Quat: \(state.orientation), Euler: \(state.euler)")
        print("Buttons: \(state.buttons), Trigger: \(state.trigger)")
        print("Tick Loss: \(state.lossPercent)%, Packet Rate: \(state.packetRateHz) Hz")
    }
    .store(in: &cancellables)
```

### 3. Measure Latency via FF15 Echo

```swift
client.echoLatencyPublisher
    .sink { sample in
        print("Round trip: \(sample.roundTripTimeMs) ms, ESP turnaround: \(sample.espTurnaroundUs) µs, queue: \(sample.espQueueDepth)")
    }
    .store(in: &cancellables)

// Send periodic pings (e.g. 50 ms / 250 ms / 1000 ms)
client.sendEchoPing()
```

### 4. Dual-Bridge Setup (Zero Contention)

```swift
let multiBridge = WMRMultiBridgeSession()
multiBridge.leftBridgeSession.bleManager.connect(to: leftBridge)
multiBridge.rightBridgeSession.bleManager.connect(to: rightBridge)
multiBridge.setStreamMode(.batchedFF14)
```

## Running Tests

From the package directory:

```bash
swift test
```
