import 'wmr_ws_protocol.dart';

/// One Wi-Fi bridge the transport may connect to.
///
/// Endpoints come either from the caller (the host and port typed into a
/// connection screen) or from `WmrWsDiscovery`. Both kinds are offered by
/// `WmrWsTransport.scan()` after the transport has registered the discovered
/// ones.
class WmrWsEndpoint {
  WmrWsEndpoint({
    required this.host,
    this.port = wmrWsDefaultPort,
    this.path = wmrWsDefaultPath,
    this.deviceId,
    this.name,
    this.token,
    this.secure = false,
    this.bridgeId,
    Iterable<String> candidateHosts = const <String>[],
  }) : hosts = _hostList(host, candidateHosts) {
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
  ///
  /// This is the first entry of [hosts], the address that [uri] and
  /// [resolvedDeviceId] name. The remaining entries are fallbacks, in the order
  /// discovery reported them.
  final String host;

  /// Every host this endpoint may try, starting with [host].
  ///
  /// One bridge answers on more than one interface (for example `eth0` and
  /// `wlan0`); discovery reports those as a single endpoint so a failed
  /// address is retried against the next one instead of appearing as a separate
  /// device. Hand-configured endpoints have exactly one entry.
  final List<String> hosts;

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

  /// Stable identity the bridge is expected to report in its WebSocket
  /// `hello`.
  ///
  /// Null for an endpoint the caller configured by hand. A discovered endpoint
  /// carries the `bridge_id` from its UDP or mDNS reply; [WmrWsTransport]
  /// refuses to authenticate unless `hello.bridge_id` matches, so a stale or
  /// wrong-host reply is not sent the token.
  final String? bridgeId;

  /// `ws://host:port/path` or `wss://host:port/path`.
  Uri get uri => uriFor(host);

  /// The same URI for one of [hosts].
  Uri uriFor(String host) =>
      Uri(scheme: secure ? 'wss' : 'ws', host: host, port: port, path: path);

  /// The device id this endpoint registers under.
  String get resolvedDeviceId => deviceId ?? '$host:$port';

  /// A copy that offers [candidateHosts] in addition to [host].
  WmrWsEndpoint withCandidateHosts(Iterable<String> candidateHosts) =>
      WmrWsEndpoint(
        host: host,
        candidateHosts: candidateHosts,
        port: port,
        path: path,
        deviceId: deviceId,
        name: name,
        token: token,
        secure: secure,
        bridgeId: bridgeId,
      );

  /// A copy for one of [hosts], used by the transport to try them in order.
  WmrWsEndpoint forHost(String host) => WmrWsEndpoint(
    host: host,
    port: port,
    path: path,
    deviceId: deviceId,
    name: name,
    token: token,
    secure: secure,
    bridgeId: bridgeId,
  );

  /// Name reported by `scan()`.
  String get displayName => name ?? 'WMR Bridge ($host)';

  static List<String> _hostList(String host, Iterable<String> candidateHosts) {
    final seen = <String>{host};
    return List<String>.unmodifiable(<String>[
      host,
      for (final candidate in candidateHosts)
        if (candidate.trim().isNotEmpty && seen.add(candidate)) candidate,
    ]);
  }
}
