# Changelog

## 0.2.1

- Version aligned with the v0.2.1 gate and harness release; `wmr_core` and `wmr_tracking` constraints raised to `^0.2.1`. No breaking public API change.

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Initial release of the public, framework-agnostic facade for the WMR Bridge controller pipeline.
- `WmrCompanion` high-level facade managing discovery, connection, stream mode switching, auto-reconnect, and teardown.
- Unified reactive streams for host consumption:
  - `controllers`: per-sample raw frames or decoded updates (`WmrControllerUpdate`).
  - `gamepad`: combined two-handed gamepad state (`GamepadState`).
  - `link`: link quality snapshots including RSSI, MTU, connection interval, stream mode, and fault counters (`WmrLinkSnapshot`).
  - `failures`: stream mode faults and non-fatal errors.
- Bridge firmware version read over FF16 (`wmrBridgeVersionCharUuid`) once after connect and published as `WmrCompanion.protocol` and `WmrLinkSnapshot.protocol` (`WmrProtocolVersion`). A bridge without FF16 reports a normal older-firmware status without gating the stream.
- Re-export `WmrBridgeFeature`, `WmrBridgeFeatures` and `WmrProtocolVersion`.
- Runtime configuration:
  - Stream mode selection (FF11 raw, FF12 decoded, FF14 batched).
  - Dynamic fusion tuning, stick centering, and axis remapping.
  - FF13 controller calibration storage across reconnects.
- Clean error hierarchy (`WmrConnectionException`, `WmrStreamModeException`, `WmrTransportException`, `WmrConfigException`).
- Standalone testing utilities in `package:wmr_companion/testing.dart`.
