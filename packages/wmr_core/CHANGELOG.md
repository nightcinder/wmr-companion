# Changelog

## Unreleased

- Add the FF16 UUID (`wmrBridgeVersionCharUuid`) and
  `lib/protocol/firmware_version.dart`: `WmrProtocolVersion`,
  `WmrBridgeFeatures` / `WmrBridgeFeature`, and the firmware-version parser.
  A missing characteristic or a malformed value is a status, not an error.
- `FakeWmrBridge` serves FF16 and accepts `firmwareVersion` /
  `firmwareVersionBytes`; `fakeBridgeDevice` now advertises FF16 too.
