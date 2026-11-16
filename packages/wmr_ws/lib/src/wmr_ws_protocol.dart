/// Constants of the Wi-Fi bridge wire protocol, version 1.
///
/// Normative source: WMR_Bridge `docs/PI_BRIDGE.md`, section "Wire protocol,
/// version 1" (branch `feat/pi-wifi-bridge`, PR #47). This package only
/// implements the client half.
library;

import 'package:wmr_core/protocol/gatt.dart';

/// The one WebSocket subprotocol this client offers.
const String wmrWsSubprotocol = 'wmr-wifi-v1';

/// Numeric protocol version carried in `hello.protocol`.
const int wmrWsProtocolVersion = 1;

/// Default control port of the daemon (`--port`).
const int wmrWsDefaultPort = 8765;

/// Default HTTP path of the daemon.
const String wmrWsDefaultPath = '/wmr';

/// First `id` reserved for the transport's own liveness probes.
///
/// An FF15 echo request carries a 16-bit ping id, so the daemon echoes back a
/// value below this base for every echo answer. A `pong` at or above it is a
/// reply to `WmrWsTransport`'s keepalive and must never be synthesized into an
/// echo answer. Protocol 1 echoes `id` verbatim
/// (WMR_Bridge `docs/PI_BRIDGE.md`, "Wire protocol, version 1").
const int wmrWsLivenessPingIdBase = 0x10000;

/// The three payload streams and the `BleTransport` characteristic each one
/// maps to. The UUIDs are the firmware constants from `wmr_core`, not new
/// strings: the Wi-Fi bridge carries the same FF11/FF12/FF14 payloads.
const Map<String, String> wmrWsStreamCharacteristics = {
  'raw': wmrBridgeStreamCharUuid,
  'decoded': wmrBridgeDecodedCharUuid,
  'batched': wmrBridgeBatchedCharUuid,
};
