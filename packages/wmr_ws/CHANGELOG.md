# Changelog

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Initial release of the Wi-Fi transport for the WMR Bridge Pi daemon
  (WMR_Bridge PR #47, protocol version 1).
- `WmrWsTransport` implements the existing `BleTransport` seam from `wmr_core`,
  so `ControllerService`, the FF11 reassembler and the FF12/FF14 parsers are
  reused unchanged.
- WebSocket handshake with subprotocol `wmr-wifi-v1`, optional shared-token
  authentication, and mapping of `stream_active` to
  `BleStreamFaultKind.otherStreamActive`.
- FF11/FF12/FF14 payloads, FF15 echo via JSON `ping`/`pong`, FF16 from
  `hello.version`, and null `rssi`/`connectionIntervalUs`/`phy` because a
  WebSocket cannot observe them.
- Host tests against an in-process loopback WebSocket server, and a documented
  `--replay` loopback check against the real daemon.
