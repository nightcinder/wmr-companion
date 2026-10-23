# wmr_core

Pure-Dart core of the WMR Bridge pipeline: the wire protocol, the per-hand
controller pipeline, the `BleTransport` seam and the controller service. No
Flutter, no Riverpod, no plugins — it runs and is tested with plain `dart test`.

This package is the foundation under `wmr_companion`; host apps usually import
the facade instead of this package directly.

## What is in it

- **Protocol:** GATT ids; FF11 fragmented frames and reassembly; FF12 decoded
  records and FF14 batches; FF13 config blocks; FF15 echo; FF16 bridge status,
  including the firmware version (`WmrProtocolVersion`). Golden-vector fixtures
  live in `test/fixtures/`.
- **Domain:** device-tick timing, gyro bias, FF13 calibration, axis mapping,
  stick centre/dead zone, the per-hand fused pipeline and the stateless gamepad
  mapper.
- **Transport seam:** the `BleTransport` interface, `MonotonicClock`,
  connection/link models and typed stream faults. Implementations live in
  `wmr_ble`; `FakeTransport`/`FakeWmrBridge` drive tests without a phone.
- **Service:** `ControllerService` (FF11/FF12/FF14 subscription, mode switching,
  counters and fault reporting) and the pure capture/latency/config services.

## Use

```yaml
dependencies:
  wmr_core:
    path: packages/wmr_core
```

```dart
import 'package:wmr_core/services/controller_service.dart';

final service = ControllerService(transport, deviceId, mode: StreamMode.batched);
await service.start();
service.decodedSamples.listen((sample) {
  // sample.orientation, sample.stick, sample.record
});
```

For a host app, prefer `package:wmr_companion` — it exposes the same pipeline
as a small, framework-agnostic facade.

## Tests

```sh
dart pub get
dart analyze
dart test
```

## Status and licence

Pre-1.0 (`0.1.0`), API frozen for the phase-8 preparation but **not published**
to pub.dev yet; see `docs/PUBLISHING.md` in the repository. MIT; the Monado XOR
key table is never bundled and the host supplies it (see the repository docs).
