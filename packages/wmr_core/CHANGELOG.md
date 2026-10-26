# Changelog

## 0.2.0

- FF17 controller control: `ControllerCommand`, `ControllerResult`,
  `ControllerStatusV2` and `encodeControllerCommand` in
  `protocol/controller_control.dart`, plus `ControllerControlClient`
  (`isSupported`, `readStatus`, `statusStream`, `send`).
- `FakeWmrBridge` serves FF17 and simulates discovery, connect/disconnect and
  the forget guards.

## 0.1.0

- Initial extraction of the pure-Dart protocol, domain, and service pipeline for the WMR Bridge.
- Protocol decoders and encoders:
  - GATT characteristic UUID definitions for the WMR Bridge service.
  - FF11 raw controller report framing and fragmentation reassembly (`WmrFragmentReassembler`).
  - FF12 decoded single-record stream parsing (`DecodedReportRecord`).
  - FF14 batched decoded record stream parsing (`DecodedBatchRecord`).
  - Bridge status characteristic parsing (16-byte state payload).
  - FF13 configuration block cursor reads and window unpacking with CRC-32 verification.
  - FF15 echo/ping client and round-trip latency tracking.
  - FF16 bridge firmware version characteristic (`wmrBridgeVersionCharUuid`), parser, and GATT feature matrix (`WmrBridgeFeatures` / `WmrBridgeFeature`, `WmrProtocolVersion`).
- Domain pipeline:
  - Multi-bridge and dual-hand management (`ControllerService`, `HandPipeline`).
  - Orientation estimation integrating `wmr_fusion` filters with axis mapping and gyro bias compensation.
  - Dual-controller gamepad mapping (`GamepadMapper`) translating WMR controller inputs to standard gamepad states.
  - Dynamic stick rest-centre learning and compensation (`StickCentreEstimator`).
  - Decoded stream statistics, sequence loss counters, and rolling loss window tracking.
- BLE transport abstraction:
  - Framework-agnostic `BleTransport` interface.
  - In-memory `FakeTransport` and firmware-accurate `FakeWmrBridge` test fixtures (including FF16 support).
- Diagnostics and recording services:
  - Controller frame capture recording (`CaptureRecorder`) in Python-compatible format.
  - Latency run recording (`LatencyRecorder`).
  - Gamepad and stick settings persistence stores.
