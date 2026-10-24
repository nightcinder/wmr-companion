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

/// The three payload streams and the `BleTransport` characteristic each one
/// maps to. The UUIDs are the firmware constants from `wmr_core`, not new
/// strings: the Wi-Fi bridge carries the same FF11/FF12/FF14 payloads.
const Map<String, String> wmrWsStreamCharacteristics = {
  'raw': wmrBridgeStreamCharUuid,
  'decoded': wmrBridgeDecodedCharUuid,
  'batched': wmrBridgeBatchedCharUuid,
};
