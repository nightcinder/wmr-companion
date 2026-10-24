# wmr_core

Pure-Dart protocol, controller pipeline, orientation estimation, and gamepad mapping for the [WMR Bridge](https://github.com/nightcinder/WMR_Bridge).

This package contains the core domain logic, protocol decoders, and transport abstractions used by `wmr_companion`. It has no Flutter SDK dependency and runs in pure Dart environments.

## Features

- **Protocol decoders & encoders:**
  - GATT characteristic UUID definitions for the WMR Bridge service.
  - FF11 raw controller report framing and fragmentation reassembly (`WmrFragmentReassembler`).
  - FF12 decoded single-record stream parsing (`DecodedReportRecord`).
  - FF14 batched decoded record stream parsing (`DecodedBatchRecord`).
  - Bridge status characteristic parsing (16-byte state payload).
  - FF13 configuration block cursor reads and window unpacking with CRC-32 verification (`ConfigClient`).
  - FF15 echo/ping client and round-trip latency tracking (`EchoClient`).
  - FF16 bridge firmware version parsing (`WmrProtocolVersion`) and GATT feature matrix (`WmrBridgeFeatures`).
- **Domain pipeline:**
  - Dual-controller and multi-bridge coordination (`ControllerService`, `HandPipeline`).
  - Orientation estimation integrating `wmr_fusion` filters with axis mapping and runtime gyro bias compensation.
  - Dual-controller gamepad mapping (`GamepadMapper`) translating WMR inputs into standard gamepad state.
  - Dynamic thumbstick rest-centre learning and dead-zone compensation (`StickCentreEstimator`).
  - Stream loss tracking, sequence loss counters, and rolling window loss statistics (`LossWindowStats`).
- **Transport abstraction:**
  - Framework-agnostic `BleTransport` interface.
  - In-memory `FakeTransport` and firmware-accurate `FakeWmrBridge` test fixtures.
- **Recording & diagnostics:**
  - Frame capture recording (`CaptureRecorder`) in desktop-compatible format.
  - Latency run recording (`LatencyRecorder`).
  - Gamepad and stick settings persistence models.

## Usage

Most applications should depend on `wmr_companion` for a high-level facade. Use `wmr_core` directly if building custom pipelines or running in a headless Dart server/CLI environment without Flutter.

```dart
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/services/controller_service.dart';

// Coordinate raw, decoded, or batched streams over an abstract BleTransport:
final service = ControllerService(
  transport: myTransport,
  mode: StreamMode.decoded,
);
```

## Testing

```sh
dart pub get
dart analyze
dart test
```

## License

MIT
