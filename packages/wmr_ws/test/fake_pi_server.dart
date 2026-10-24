import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// In-process stand-in for `wmr_bridge`'s WebSocket server, protocol 1.
///
/// It listens on a real loopback socket and speaks real WebSocket frames, so
/// the tests exercise the code that runs against a Pi rather than a mocked
/// socket. Behaviour that the transport must handle (auth accepted, rejected
/// or ignored; `stream_active`; slow consumers) is configurable per server.
class FakePiServer {
  FakePiServer._(this._server, this._options);

  final HttpServer _server;
  final FakePiOptions _options;
  final List<WebSocket> _clients = [];
  final List<Map<String, Object?>> messages = [];
  final Completer<void> _connected = Completer<void>();

  int get port => _server.port;
  String get url => 'ws://127.0.0.1:$port/wmr';
  List<WebSocket> get clients => List.unmodifiable(_clients);
  String? get negotiatedProtocol =>
      _clients.isEmpty ? null : _clients.first.protocol;

  static Future<FakePiServer> start([FakePiOptions? options]) async {
    final opts = options ?? const FakePiOptions();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakePiServer._(server, opts);
    server.listen((request) async {
      if (request.uri.path != '/wmr') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (protocols) =>
            protocols.contains('wmr-wifi-v1') ? 'wmr-wifi-v1' : null,
        compression: CompressionOptions.compressionOff,
      );
      fake._clients.add(ws);
      ws.listen(
        (dynamic data) => fake._onMessage(ws, data),
        onDone: () => fake._clients.remove(ws),
        onError: (Object _) => fake._clients.remove(ws),
      );
      if (!fake._connected.isCompleted) fake._connected.complete();
      if (opts.sendHello) {
        if (opts.helloDelay > Duration.zero) {
          Timer(opts.helloDelay, () => fake.sendText(opts.helloJson()));
        } else {
          fake.sendText(opts.helloJson());
        }
      }
    });
    return fake;
  }

  /// Completes when the first client socket has been upgraded.
  Future<void> get connected => _connected.future;

  void sendText(Map<String, Object?> message) {
    final text = jsonEncode(message);
    for (final client in _clients) {
      client.add(text);
    }
  }

  void sendTextJson(String text) {
    for (final client in _clients) {
      client.add(text);
    }
  }

  void sendBinary(List<int> bytes) {
    for (final client in _clients) {
      client.add(Uint8List.fromList(bytes));
    }
  }

  /// Closes every client socket with [code].
  Future<void> closeClients([int code = 1000, String reason = '']) async {
    for (final client in List<WebSocket>.of(_clients)) {
      await client.close(code, reason);
    }
  }

  /// Stops listening and closes any client. Safe to call twice.
  Future<void> stop() async {
    await closeClients();
    await _server.close(force: true);
  }

  void _onMessage(WebSocket ws, dynamic data) {
    if (data is! String) {
      sendText({'type': 'error', 'code': 'binary_not_accepted'});
      return;
    }
    final decoded = jsonDecode(data);
    if (decoded is! Map<String, Object?>) return;
    messages.add(decoded);
    switch (decoded['type']) {
      case 'auth':
        switch (_options.authMode) {
          case FakeAuthMode.accept:
            sendText({'type': 'auth_ok'});
          case FakeAuthMode.reject:
            sendText({'type': 'error', 'code': 'auth_failed'});
            ws.close(4401, 'auth_failed');
          case FakeAuthMode.ignore:
            break;
        }
      case 'subscribe':
        final error = _options.subscribeError;
        if (error != null) {
          sendText({'type': 'error', 'code': error});
          return;
        }
        final stream = decoded['stream'];
        _activeStream = stream is String ? stream : null;
        sendText({
          'type': 'subscribed',
          'stream': stream,
          'recordSize': _options.recordSize,
          'batchMax': _options.batchMax,
          'fragmentCapacity': _options.fragmentCapacity,
        });
      case 'unsubscribe':
        _activeStream = null;
        sendText({'type': 'unsubscribed'});
      case 'status':
        sendText(_options.statusJson());
      case 'ping':
        sendText({
          'type': 'pong',
          'id': decoded['id'],
          't': decoded['t'],
          'serverTimeUs': _options.serverTimeUs,
        });
      case 'close':
        ws.close(1000, 'client asked');
      default:
        sendText({'type': 'error', 'code': 'unknown_type'});
    }
  }

  String? _activeStream;
  String? get activeStream => _activeStream;

  /// Messages of one type, oldest first.
  List<Map<String, Object?>> messagesOfType(String type) =>
      messages.where((m) => m['type'] == type).toList();
}

enum FakeAuthMode { accept, reject, ignore }

class FakePiOptions {
  const FakePiOptions({
    this.authRequired = false,
    this.authMode = FakeAuthMode.accept,
    this.sendHello = true,
    this.helloDelay = Duration.zero,
    this.version = '0.1.0-test',
    this.hostname = 'fake-pi',
    this.device = 'wmr-pi',
    this.streams = const ['raw', 'decoded', 'batched'],
    this.recordSize = 56,
    this.batchMax = 9,
    this.fragmentCapacity = 244,
    this.subscribeError,
    this.serverTimeUs = 123456789,
    this.statusHands = 2,
  });

  final bool authRequired;
  final FakeAuthMode authMode;
  final bool sendHello;
  final Duration helloDelay;
  final String version;
  final String hostname;
  final String device;
  final List<String> streams;
  final int recordSize;
  final int batchMax;
  final int fragmentCapacity;

  /// When set, every subscribe is answered with this error code.
  final String? subscribeError;
  final int serverTimeUs;
  final int statusHands;

  Map<String, Object?> helloJson() => {
    'type': 'hello',
    'protocol': 1,
    'transport': 'wifi',
    'device': device,
    'version': version,
    'hostname': hostname,
    'authRequired': authRequired,
    'streams': streams,
    'recordSize': recordSize,
    'batchMax': batchMax,
    'fragmentCapacity': fragmentCapacity,
  };

  Map<String, Object?> statusJson() => {
    'type': 'status',
    'uptimeS': 1.5,
    'hostTimeUs': serverTimeUs,
    'hands': [
      for (var hand = 0; hand < statusHands; hand++)
        {
          'hand': hand == 0 ? 'LEFT' : 'RIGHT',
          'connected': true,
          'address': 'AA:BB:CC:DD:EE:0$hand',
          'reports': 100 + hand,
          'decoded': 90 + hand,
          'errors': 0,
          'delivered': 90 + hand,
          'dropped': hand,
          'sequence': 100 + hand,
          'lastRxAgeMs': 6.2,
        },
    ],
    'clients': 1,
    'subscribed': 1,
    'dropped': 3,
    'batches': 42,
  };
}
