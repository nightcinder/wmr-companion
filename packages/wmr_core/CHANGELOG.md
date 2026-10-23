# Changelog

## 0.1.0

- First frozen line (pre-1.0). Pure-Dart core extracted from the companion app:
  FF11/FF12/FF14/FF13/FF15/FF16 protocol, domain timing and fusion pipeline,
  the `BleTransport` seam, `ControllerService` and the pure capture, latency,
  config and settings services.
- Golden-vector fixtures moved here from the app.
- Add the FF16 UUID (`wmrBridgeVersionCharUuid`) and
  `lib/protocol/firmware_version.dart`: `WmrProtocolVersion`,
  `WmrBridgeFeatures` / `WmrBridgeFeature`, and the firmware-version parser.
  A missing characteristic or a malformed value is a status, not an error.
- `FakeWmrBridge` serves FF16 and accepts `firmwareVersion` /
  `firmwareVersionBytes`; `fakeBridgeDevice` now advertises FF16 too.
- Not published to pub.dev yet; see `docs/PUBLISHING.md`.
