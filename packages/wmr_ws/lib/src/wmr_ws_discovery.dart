import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'wmr_ws_endpoint.dart';
import 'wmr_ws_protocol.dart';

/// The UDP probe the Pi bridge answers. The nonce after the space is echoed
/// in the reply so a late or unrelated datagram cannot be mistaken for one of
/// ours.
const String wmrWsDiscoveryProbe = 'WMR_DISCOVER_V1';

/// DNS-SD service type the Pi bridge can advertise with `--advertise-mdns`.
const String wmrWsMdnsServiceType = '_wmr-bridge._tcp.local';

/// LAN discovery for [WmrWsEndpoint]s, using `dart:io` only.
///
/// Two paths run in parallel for [timeout]:
///
/// * A UDP probe (`WMR_DISCOVER_V1 <nonce>`) broadcast to port 8765. The
///   responder replies by unicast with JSON metadata (`nonce`, `bridge_id`,
///   `name`, `port`, `path`, `hands`, `version`, `auth`), including the echoed
///   nonce and a stable `bridge_id`.
/// * A DNS-SD query for `_wmr-bridge._tcp.local`, sent to the mDNS group from
///   an ephemeral port with the QU bit set. Replies are unicast, so the caller
///   never binds port 5353 and Android needs no `MulticastLock`. The PTR/SRV/
///   TXT/A records are assembled across packets; the TXT record supplies
///   `id=<bridge_id>` and `path`.
///
/// A reply is a hint, not authentication: it never carries the token. Callers
/// that configure a token should put the reported `bridgeId` on
/// [WmrWsEndpoint.bridgeId]; [WmrWsTransport.connect] then refuses to
/// authenticate unless the WebSocket `hello` reports the same id.
///
/// Discovery is best-effort. A host with no network, a blocked broadcast or a
/// disabled mDNS responder simply yields no endpoints; it does not throw.
class WmrWsDiscovery {
  WmrWsDiscovery({
    this.timeout = const Duration(seconds: 1),
    this.udpPort = wmrWsDefaultPort,
    this.mdnsPort = 5353,
    List<InternetAddress>? probeAddresses,
    InternetAddress? mdnsAddress,
    Random? random,
  }) : probeAddresses =
           probeAddresses ??
           <InternetAddress>[InternetAddress('255.255.255.255')],
       mdnsAddress = mdnsAddress ?? InternetAddress('224.0.0.251'),
       _random = random ?? Random.secure();

  /// How long either path listens for replies. Both run concurrently.
  final Duration timeout;

  /// UDP port of the discovery responder; the daemon's WebSocket port.
  final int udpPort;

  /// mDNS port. The query is sent here, but the answering socket is bound to
  /// an ephemeral port.
  final int mdnsPort;

  /// Where UDP probes are sent. Defaults to the limited broadcast address.
  final List<InternetAddress> probeAddresses;

  /// mDNS group address. Defaults to 224.0.0.251.
  final InternetAddress mdnsAddress;

  final Random _random;

  /// Runs both paths and returns every endpoint whose reply verified.
  ///
  /// Results are deduplicated by [WmrWsEndpoint.resolvedDeviceId]; the first
  /// reply for a host and port wins.
  Future<List<WmrWsEndpoint>> discover() async {
    final results = <String, WmrWsEndpoint>{};
    final nonce = _newNonce();
    await Future.wait<void>([_probeUdp(nonce, results), _queryMdns(results)]);
    return List<WmrWsEndpoint>.unmodifiable(results.values);
  }

  String _newNonce() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _probeUdp(
    String nonce,
    Map<String, WmrWsEndpoint> results,
  ) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        final endpoint = _parseUdpReply(
          datagram.data,
          nonce: nonce,
          host: datagram.address.address,
        );
        if (endpoint != null) _remember(results, endpoint);
      }, onError: (Object _) {});
      final probe = Uint8List.fromList(
        utf8.encode('$wmrWsDiscoveryProbe $nonce'),
      );
      for (final address in probeAddresses) {
        try {
          socket.send(probe, address, udpPort);
        } on SocketException {
          // One unreachable broadcast target does not invalidate the rest.
        }
      }
      await Future<void>.delayed(timeout);
    } on SocketException {
      // No usable IPv4 interface or broadcast permission: discovery is a
      // convenience, so an empty result is the correct answer.
    } finally {
      socket?.close();
    }
  }

  Future<void> _queryMdns(Map<String, WmrWsEndpoint> results) async {
    RawDatagramSocket? socket;
    final records = _MdnsRecords();
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        try {
          records.absorb(datagram.data);
        } on FormatException {
          // A malformed or truncated mDNS packet is not a discovery result.
        }
      }, onError: (Object _) {});
      socket.send(_mdnsQuery(), mdnsAddress, mdnsPort);
      await Future<void>.delayed(timeout);
      for (final endpoint in records.endpoints()) {
        _remember(results, endpoint);
      }
    } on SocketException {
      // Same as above: no multicast route means no mDNS results, not a
      // transport failure.
    } finally {
      socket?.close();
    }
  }

  static void _remember(
    Map<String, WmrWsEndpoint> results,
    WmrWsEndpoint endpoint,
  ) {
    results.putIfAbsent(endpoint.resolvedDeviceId, () => endpoint);
  }

  static WmrWsEndpoint? _parseUdpReply(
    Uint8List data, {
    required String nonce,
    required String host,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(data));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['nonce'] != nonce) return null;
    final bridgeId = decoded['bridge_id'];
    if (bridgeId is! String || bridgeId.isEmpty) return null;

    final rawPort = decoded['port'];
    final port = rawPort is num && rawPort >= 1 && rawPort <= 65535
        ? rawPort.toInt()
        : wmrWsDefaultPort;
    final rawPath = decoded['path'];
    final path = rawPath is String && rawPath.startsWith('/')
        ? rawPath
        : wmrWsDefaultPath;
    final rawName = decoded['name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName
        : null;
    return WmrWsEndpoint(
      host: host,
      port: port,
      path: path,
      bridgeId: bridgeId,
      name: name,
    );
  }

  static Uint8List _mdnsQuery() {
    final builder = BytesBuilder(copy: false);
    // ID 0, flags 0, one question, no records.
    builder.add(const <int>[0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    builder.add(_encodeDnsName(wmrWsMdnsServiceType));
    // PTR, class IN with the unicast-response (QU) bit set.
    builder.add(const <int>[0, 12, 0x80, 0x01]);
    return builder.toBytes();
  }
}

class _Srv {
  const _Srv(this.port, this.target);

  final int port;
  final String target;
}

/// Records gathered from one or more mDNS response packets. Packets can be
/// split, so PTR/SRV/TXT/A records are merged by name before endpoints are
/// built.
class _MdnsRecords {
  final Map<String, _Srv> _srv = {};
  final Map<String, Map<String, String>> _txt = {};
  final Map<String, InternetAddress> _ipv4 = {};
  final Map<String, InternetAddress> _ipv6 = {};

  void absorb(Uint8List data) {
    final reader = _DnsReader(data);
    if (!reader.readHeader()) return;
    for (var i = 0; i < reader.questionCount; i++) {
      reader.readName();
      reader.skip(4);
    }
    final records =
        reader.answerCount + reader.authorityCount + reader.additionalCount;
    for (var i = 0; i < records; i++) {
      final name = _normalize(reader.readName());
      final type = reader.readUint16();
      reader.readUint16(); // class
      reader.readUint32(); // ttl
      final length = reader.readUint16();
      final dataStart = reader.offset;
      final dataEnd = dataStart + length;
      if (dataEnd > data.length) return;
      switch (type) {
        case 1:
          if (length == 4) {
            _ipv4[name] = InternetAddress.fromRawAddress(
              Uint8List.fromList(data.sublist(dataStart, dataEnd)),
            );
          }
        case 28:
          if (length == 16) {
            _ipv6[name] = InternetAddress.fromRawAddress(
              Uint8List.fromList(data.sublist(dataStart, dataEnd)),
            );
          }
        case 12:
          // PTR target is the instance name; SRV/TXT carry the details.
          reader.readName();
        case 16:
          if (_isInstanceName(name)) {
            _txt[name] = _parseTxt(data, dataStart, dataEnd);
          }
        case 33:
          if (_isInstanceName(name) && dataStart + 6 <= dataEnd) {
            reader.readUint16(); // priority
            reader.readUint16(); // weight
            final port = reader.readUint16();
            _srv[name] = _Srv(port, reader.readName());
          }
      }
      reader.offset = dataEnd;
    }
  }

  List<WmrWsEndpoint> endpoints() {
    final endpoints = <WmrWsEndpoint>[];
    for (final entry in _srv.entries) {
      final instance = entry.key;
      final txt = _txt[instance] ?? const <String, String>{};
      final bridgeId = txt['id'] ?? txt['bridge_id'];
      if (bridgeId == null || bridgeId.isEmpty) continue;
      final srv = entry.value;
      if (srv.port < 1 || srv.port > 65535) continue;

      final target = _normalize(srv.target);
      final host =
          _ipv4[target]?.address ??
          _ipv6[target]?.address ??
          _normalize(srv.target);
      if (host.isEmpty) continue;

      final rawPath = txt['path'];
      final path = rawPath != null && rawPath.startsWith('/')
          ? rawPath
          : wmrWsDefaultPath;
      final label = _instanceLabel(instance);
      endpoints.add(
        WmrWsEndpoint(
          host: host,
          port: srv.port,
          path: path,
          bridgeId: bridgeId,
          name: label.isEmpty ? null : label,
        ),
      );
    }
    return endpoints;
  }

  static String _instanceLabel(String instance) {
    final suffix = '.${_normalize(wmrWsMdnsServiceType)}';
    if (instance.endsWith(suffix)) {
      return instance.substring(0, instance.length - suffix.length);
    }
    return instance;
  }

  static bool _isInstanceName(String name) =>
      name.endsWith('.${_normalize(wmrWsMdnsServiceType)}');

  static Map<String, String> _parseTxt(Uint8List data, int start, int end) {
    final values = <String, String>{};
    var offset = start;
    while (offset < end) {
      final length = data[offset++];
      if (offset + length > end) break;
      final item = utf8.decode(
        data.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      final equals = item.indexOf('=');
      if (equals > 0) {
        values[item.substring(0, equals).toLowerCase()] = item.substring(
          equals + 1,
        );
      } else if (item.isNotEmpty) {
        values[item.toLowerCase()] = '';
      }
    }
    return values;
  }
}

class _DnsReader {
  _DnsReader(this.data);

  final Uint8List data;
  int offset = 0;
  int questionCount = 0;
  int answerCount = 0;
  int authorityCount = 0;
  int additionalCount = 0;

  bool readHeader() {
    if (data.length < 12) return false;
    readUint16(); // id
    final flags = readUint16();
    questionCount = readUint16();
    answerCount = readUint16();
    authorityCount = readUint16();
    additionalCount = readUint16();
    // Ignore queries and anything that is not a response.
    return (flags & 0x8000) != 0;
  }

  int readUint8() {
    if (offset >= data.length) throw const FormatException('DNS past end');
    return data[offset++];
  }

  int readUint16() {
    final high = readUint8();
    final low = readUint8();
    return (high << 8) | low;
  }

  int readUint32() {
    final high = readUint16();
    final low = readUint16();
    return (high << 16) | low;
  }

  void skip(int count) {
    if (offset + count > data.length) {
      throw const FormatException('DNS past end');
    }
    offset += count;
  }

  String readName() {
    final labels = <String>[];
    final visited = <int>{};
    var position = offset;
    var jumpOffset = -1;
    while (true) {
      if (position >= data.length) {
        throw const FormatException('DNS name past end');
      }
      final length = data[position];
      if (length == 0) {
        position++;
        break;
      }
      if ((length & 0xC0) == 0xC0) {
        if (position + 1 >= data.length) {
          throw const FormatException('DNS pointer past end');
        }
        final pointer = ((length & 0x3F) << 8) | data[position + 1];
        if (jumpOffset < 0) jumpOffset = position + 2;
        if (!visited.add(pointer) || pointer >= data.length) {
          throw const FormatException('DNS pointer loop');
        }
        position = pointer;
        continue;
      }
      if ((length & 0xC0) != 0) {
        throw const FormatException('unsupported DNS label');
      }
      position++;
      if (position + length > data.length) {
        throw const FormatException('DNS label past end');
      }
      labels.add(
        utf8.decode(
          data.sublist(position, position + length),
          allowMalformed: true,
        ),
      );
      position += length;
    }
    offset = jumpOffset < 0 ? position : jumpOffset;
    return labels.join('.');
  }
}

Uint8List _encodeDnsName(String name) {
  final builder = BytesBuilder(copy: false);
  for (final label in name.split('.')) {
    final bytes = utf8.encode(label);
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0);
  return builder.toBytes();
}

String _normalize(String name) {
  var value = name.toLowerCase();
  while (value.endsWith('.')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}
