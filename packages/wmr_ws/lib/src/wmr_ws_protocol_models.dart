import 'wmr_ws_exceptions.dart';
import 'wmr_ws_protocol.dart';

/// The JSON `hello` the daemon sends immediately after the socket opens.
///
/// Every field is what the daemon reported; nothing is inferred. `streams` is
/// the set of payload streams this build can serve (`raw`, `decoded`,
/// `batched`) and is what [discoverServices][BleTransport.discoverServices]
/// synthesizes the FF10 table from.
class WmrWsHello {
  WmrWsHello({
    required this.protocol,
    required this.transport,
    required this.device,
    required this.version,
    required this.hostname,
    required this.authRequired,
    required Set<String> streams,
    required this.recordSize,
    required this.batchMax,
    required this.fragmentCapacity,
  }) : streams = Set.unmodifiable(streams);

  /// Parses a decoded JSON control message. Throws
  /// [WmrWsHandshakeException] when it is not a usable version 1 `hello`.
  factory WmrWsHello.fromJson(Map<String, Object?> json) {
    if (json['type'] != 'hello') {
      throw WmrWsHandshakeException(
        'expected a hello, got ${json['type'] ?? 'no type'}',
      );
    }
    final protocol = _int(json['protocol'], 'protocol');
    if (protocol != wmrWsProtocolVersion) {
      throw WmrWsHandshakeException(
        'bridge speaks protocol $protocol; this client speaks '
        '$wmrWsProtocolVersion',
      );
    }
    final transport = _string(json['transport'], 'transport', 'wifi');
    final streams = <String>{};
    final rawStreams = json['streams'];
    if (rawStreams is List) {
      for (final item in rawStreams) {
        if (item is String) streams.add(item);
      }
    }
    return WmrWsHello(
      protocol: protocol,
      transport: transport,
      device: _string(json['device'], 'device', 'wmr-bridge'),
      version: _string(json['version'], 'version', ''),
      hostname: _string(json['hostname'], 'hostname', ''),
      authRequired: json['authRequired'] == true,
      streams: streams,
      recordSize: _int(json['recordSize'], 'recordSize', 56),
      batchMax: _int(json['batchMax'], 'batchMax', 9),
      fragmentCapacity: _int(json['fragmentCapacity'], 'fragmentCapacity', 244),
    );
  }

  final int protocol;

  /// Always `wifi` in protocol 1.
  final String transport;

  /// Human-readable daemon identity, e.g. `wmr-pi`.
  final String device;

  /// Daemon software version. This is the FF16 equivalent; it identifies the
  /// bridge software, not controller firmware.
  final String version;

  final String hostname;

  /// When true the daemon closes the socket after five seconds unless
  /// `{"type":"auth","token":...}` arrives.
  final bool authRequired;

  /// `raw`, `decoded`, `batched` — the streams `discoverServices` reports.
  final Set<String> streams;

  /// 56 in protocol 1.
  final int recordSize;

  /// 9 in protocol 1.
  final int batchMax;

  /// Largest raw fragment value the daemon emits, including the 12-byte
  /// header. This is what `connectionInfo().mtu` reports: it is a payload
  /// capacity, not an ATT MTU.
  final int fragmentCapacity;

  bool supportsStreamNamed(String name) => streams.contains(name);

  static int _int(Object? value, String field, [int? fallback]) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (fallback != null) return fallback;
    throw WmrWsHandshakeException('hello.$field is missing or not a number');
  }

  static String _string(Object? value, String field, String fallback) {
    if (value == null) return fallback;
    if (value is String) return value;
    throw WmrWsHandshakeException('hello.$field is not a string');
  }
}

/// One hand in a `status` reply.
class WmrWsHandStatus {
  const WmrWsHandStatus({
    required this.hand,
    required this.connected,
    required this.address,
    required this.reports,
    required this.decoded,
    required this.errors,
    required this.delivered,
    required this.dropped,
    required this.sequence,
    required this.lastRxAgeMs,
  });

  /// 0 LEFT, 1 RIGHT, parsed from the daemon's `"LEFT"` / `"RIGHT"`.
  final int hand;
  final bool connected;
  final String address;
  final int reports;
  final int decoded;
  final int errors;

  /// Records enqueued for a client; a batch contributes one per record.
  final int delivered;

  /// Messages dropped because a client's queue was full.
  final int dropped;
  final int sequence;
  final double? lastRxAgeMs;
}

/// The JSON `status` object (also the reply to `{"type":"status"}`).
class WmrWsStatus {
  const WmrWsStatus({
    required this.uptimeS,
    required this.hostTimeUs,
    required this.hands,
    required this.clients,
    required this.subscribed,
    required this.dropped,
    required this.batches,
  });

  factory WmrWsStatus.fromJson(Map<String, Object?> json) {
    final hands = <WmrWsHandStatus>[];
    final rawHands = json['hands'];
    if (rawHands is List) {
      for (final item in rawHands) {
        if (item is Map<String, Object?>) {
          hands.add(_hand(item, hands.length));
        }
      }
    }
    return WmrWsStatus(
      uptimeS: _double(json['uptimeS']),
      hostTimeUs: _int(json['hostTimeUs']),
      hands: List.unmodifiable(hands),
      clients: _int(json['clients']),
      subscribed: _int(json['subscribed']),
      dropped: _int(json['dropped']),
      batches: _int(json['batches']),
    );
  }

  /// Seconds since the daemon started.
  final double uptimeS;

  /// The daemon's monotonic clock, microseconds since the daemon started.
  ///
  /// This is not comparable with the phone's [MonotonicClock] and not
  /// comparable with ESP32 `esp_timer` values: the three clocks have different
  /// origins. Only differences within this one clock are meaningful.
  final int hostTimeUs;

  final List<WmrWsHandStatus> hands;
  final int clients;
  final int subscribed;

  /// Messages dropped because a client queue was full, over all clients.
  final int dropped;
  final int batches;

  static WmrWsHandStatus _hand(Map<String, Object?> json, int index) {
    final name = json['hand'];
    final lastAge = json['lastRxAgeMs'];
    return WmrWsHandStatus(
      hand: name == 'RIGHT' ? 1 : (name == 'LEFT' ? 0 : index),
      connected: json['connected'] == true,
      address: json['address'] is String ? json['address']! as String : '',
      reports: _int(json['reports']),
      decoded: _int(json['decoded']),
      errors: _int(json['errors']),
      delivered: _int(json['delivered']),
      dropped: _int(json['dropped']),
      sequence: _int(json['sequence']),
      lastRxAgeMs: lastAge is num ? lastAge.toDouble() : null,
    );
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;

  static double _double(Object? value) => value is num ? value.toDouble() : 0;
}

/// Delivery counters of one connection, local to this client.
///
/// [droppedByQueue] is the client-side counterpart of the daemon's `dropped`:
/// a frame that arrived from the socket while the consumer's queue already
/// held [WmrWsTransport.queueSize] frames is discarded (newest dropped, the
/// daemon's policy), not silently buffered forever. It is a diagnostics
/// number, not a stream error.
class WmrWsStats {
  const WmrWsStats({
    this.payloadMessages = 0,
    this.textMessages = 0,
    this.droppedByQueue = 0,
    this.unexpectedMessages = 0,
    this.controlErrors = 0,
  });

  /// Binary messages received from the daemon, whatever the stream.
  final int payloadMessages;

  /// Text control messages received.
  final int textMessages;

  /// Notifications discarded because the consumer was not keeping up.
  final int droppedByQueue;

  /// Binary messages with no stream to deliver them to, malformed JSON, or an
  /// unknown `type`.
  final int unexpectedMessages;

  /// `{"type":"error"}` messages that matched no pending request.
  final int controlErrors;

  WmrWsStats operator +(WmrWsStats other) => WmrWsStats(
    payloadMessages: payloadMessages + other.payloadMessages,
    textMessages: textMessages + other.textMessages,
    droppedByQueue: droppedByQueue + other.droppedByQueue,
    unexpectedMessages: unexpectedMessages + other.unexpectedMessages,
    controlErrors: controlErrors + other.controlErrors,
  );

  @override
  String toString() =>
      'WmrWsStats(payload: $payloadMessages, text: $textMessages, '
      'dropped: $droppedByQueue, unexpected: $unexpectedMessages, '
      'controlErrors: $controlErrors)';
}
