# Changelog

## Unreleased

- Read the bridge firmware version over FF16 (`wmrBridgeVersionCharUuid`) once
  after connect and publish it, with the FF11–FF16 feature matrix, as
  `WmrCompanion.protocol` and `WmrLinkSnapshot.protocol`
  (`WmrProtocolVersion`). A bridge without FF16 is a normal older-firmware
  status; malformed values are flagged, never thrown, and the stream is never
  gated on the read.
- Re-export `WmrBridgeFeature`, `WmrBridgeFeatures` and `WmrProtocolVersion`.
