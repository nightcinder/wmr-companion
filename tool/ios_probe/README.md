# WMR Companion iOS Probe

A native iOS diagnostic tool and GATT probe built with SwiftUI and `WMRCompanionKit`.

This tool provides a native iOS baseline for evaluating controller streaming latency, report loss %, and 3DoF orientation tracking without Flutter or platform channel overhead.

## Capabilities

- **Bridge Scanning & Connection**: Discovers advertising `WMR Bridge` peripherals, connects, negotiates MTU, and discovers GATT service `0xFF10`.
- **Selectable GATT Streams**: Switch between `None (Echo only)`, `FF11 (Raw fragmented HID)`, `FF12 (Decoded 56-byte)`, and `FF14 (Batched decoded)`.
- **FF15 Echo Round-Trip Measurement**: Sends pings at 50 ms, 250 ms, or 1000 ms intervals via `WRITE_TYPE_NO_RESPONSE`, timestamping at the nanosecond boundary upon notification callback.
- **Controller Telemetry**: Displays real-time 3DoF orientation (Euler angles: roll, pitch, yaw), digital button states, analog trigger, stick, packet rate (Hz), and tick-based loss %.
- **Standardized Export**: Emits latency summary JSON (`wmr-latency` v2 schema) and per-ping echo CSV through the iOS share sheet, compatible with cross-platform comparison tools.

## Setup & Running

1. Open the project in Xcode on macOS.
2. Ensure `WMRCompanionKit` (located in `packages/WMRCompanionKit`) is included as a local Swift package dependency.
3. Select an iOS device target (iOS 18.0 or later). Real physical hardware is required for CoreBluetooth.
4. Build and run (`Cmd + R`).
