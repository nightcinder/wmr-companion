# Changelog

## 0.1.0

- First frozen line (pre-1.0). Public facade over the WMR Bridge pipeline:
  - `WmrCompanion` lifecycle (`initialize`, `startScan`, `connect`,
    `setStreamMode`, `disconnect`, `dispose`) with explicit reconnection.
  - Broadcast streams: `bridges`, `connection`, `controllers`, `gamepad`,
    `link`, `failures`.
  - Immutable models (`WmrBridgeDevice`, `WmrControllerUpdate`, `WmrHandStats`,
    `WmrLinkSnapshot`) and typed errors.
  - `WmrCompanionConfig` with stream mode, fusion, axis mapping, gamepad and
    stick settings.
  - `FakeTransport`/`FakeWmrBridge` re-exported from `testing.dart`.
- Read the bridge firmware version over FF16 (`wmrBridgeVersionCharUuid`) once
  after connect and publish it, with the FF11–FF16 feature matrix, as
  `WmrCompanion.protocol` and `WmrLinkSnapshot.protocol`
  (`WmrProtocolVersion`). A bridge without FF16 is a normal older-firmware
  status; malformed values are flagged, never thrown, and the stream is never
  gated on the read.
- Re-export `WmrBridgeFeature`, `WmrBridgeFeatures` and `WmrProtocolVersion`.
- No Flutter, Riverpod or plugin dependency; Android and iOS host apps consume
  controller state in-process.
- Not published to pub.dev yet; see `docs/PUBLISHING.md`.
