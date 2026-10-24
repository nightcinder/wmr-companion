/// WebSocket (Wi-Fi) transport for the WMR Bridge Linux/Raspberry Pi daemon.
///
/// `WmrWsTransport` implements the existing `BleTransport` seam from
/// `wmr_core`, so `ControllerService`, the FF11 reassembler, the FF12 record
/// parser, the FF14 batch parser and `EchoClient` are reused unchanged. The
/// package is pure Dart (`dart:io` sockets, no Flutter plugin) and speaks
/// protocol version 1 of WMR_Bridge `docs/PI_BRIDGE.md`.
///
/// This is not a hardware claim: it has been exercised against the daemon in
/// `--replay` mode on a loopback socket, not against a Raspberry Pi or real
/// controllers.
library;

export 'src/wmr_ws_endpoint.dart';
export 'src/wmr_ws_exceptions.dart';
export 'src/wmr_ws_protocol.dart';
export 'src/wmr_ws_protocol_models.dart';
export 'src/wmr_ws_transport.dart';
