import 'wmr_ws_protocol.dart';

/// One Wi-Fi bridge the transport may connect to.
///
/// There is no discovery in this package: the caller supplies the host and
/// port, exactly as it would type them into a connection screen. `scan()`
/// merely reports the configured endpoints so the existing scan flow keeps
/// working.
class WmrWsEndpoint {
  WmrWsEndpoint({
    required this.host,
    this.port = wmrWsDefaultPort,
    this.path = wmrWsDefaultPath,
    this.deviceId,
    this.name,
    this.token,
    this.secure = false,
  }) {
    if (host.trim().isEmpty) {
      throw ArgumentError.value(host, 'host', 'must not be empty');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be 1..65535');
    }
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', "must start with '/'");
    }
  }

  /// Host name or IP address of the machine running `wmr_bridge`.
  final String host;

  /// Control port (`--port`, default 8765).
  final int port;

  /// HTTP path (`/wmr`).
  final String path;

  /// Transport device id. Defaults to `<host>:<port>`, which is stable across
  /// reconnects and usable as the `BleTransport` device id.
  final String? deviceId;

  /// Display name reported by `scan()`. Defaults to `WMR Bridge (<host>)`.
  final String? name;

  /// Shared token for `{"type":"auth"}`. Null when the daemon runs without
  /// one. Never logged.
  final String? token;

  /// Use `wss` (TLS) instead of `ws`. The daemon itself serves plaintext; this
  /// is for a TLS-terminating proxy in front of it.
  final bool secure;

  /// `ws://host:port/path` or `wss://host:port/path`.
  Uri get uri =>
      Uri(scheme: secure ? 'wss' : 'ws', host: host, port: port, path: path);

  /// The device id this endpoint registers under.
  String get resolvedDeviceId => deviceId ?? '$host:$port';

  /// Name reported by `scan()`.
  String get displayName => name ?? 'WMR Bridge ($host)';
}
