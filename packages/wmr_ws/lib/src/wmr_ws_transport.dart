import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/echo.dart';
import 'package:wmr_core/protocol/gatt.dart';

import 'wmr_ws_discovery.dart';
import 'wmr_ws_endpoint.dart';
import 'wmr_ws_exceptions.dart';
import 'wmr_ws_notification_sink.dart';
import 'wmr_ws_protocol.dart';
import 'wmr_ws_protocol_models.dart';

/// How the transport opens the socket. The default is `WebSocket.connect`;
/// tests that need a socket without a real server can inject their own.
typedef WmrWsConnector = Future<WebSocket> Function(Uri uri);

/// `BleTransport` over the WMR Bridge Linux/Raspberry Pi WebSocket daemon.
///
/// The daemon ([WMR_Bridge PR #47](https://github.com/nightcinder/WMR_Bridge/pull/47))
/// sends the same FF11 fragments, FF12 records and FF14 batches as the ESP32
/// over `ws://<host>:8765/wmr` with `Sec-WebSocket-Protocol: wmr-wifi-v1`.
/// This class implements the existing, GATT-shaped [BleTransport] seam rather
/// than forking the protocol: `ControllerService` and the parsers are
/// unchanged.
///
/// ## What the GATT shape does not express
///
/// * `connectionInfo().rssi`, `.connectionIntervalUs` and `.phy` are **null**.
///   A WebSocket exposes no link-layer measurements. Null keeps the ONY-98
///   meaning "not observable"; it does not mean "weak" or "1M".
/// * `mtu` is `hello.fragmentCapacity` (the largest raw fragment value), not
///   an ATT MTU. The daemon has no MTU negotiation.
/// * `read(FF11)` is not synthesized. Use [status] for the daemon's JSON
///   status; reading the 16-byte BLE status would require inventing HID
///   descriptor bits the Pi does not have.
/// * `read`/`write` on FF13 throw [WmrWsUnsupportedException]: the daemon does
///   not implement calibration. `ConfigClient` already treats an absent FF13
///   characteristic as [ConfigReadFailure.unsupported], and
///   `discoverServices` does not advertise FF13.
/// * FF15 notifications are synthesized from JSON `pong` messages. The daemon
///   has no server-side turnaround field, so the synthesized
///   [EchoAnswer.turnaroundUs] and [EchoAnswer.queueDepth] are 0 and
///   [EchoAnswer.rxTimeUs] is the daemon's `serverTimeUs`. That clock has the
///   daemon's own origin: do not compare it with the phone clock or with an
///   ESP32 timestamp. `EchoSample.offsetUs` therefore means "daemon clock
///   minus phone clock", not "ESP32 minus phone"; it is a different quantity
///   from the BLE bridge's offset. `EchoSample.rttUs` is the observable.
///
/// ## Timestamps
///
/// Every binary message is stamped from [clock] at the very first statement of
/// the socket callback, before JSON typing, stream lookup or queuing. A frame
/// delayed by the client queue therefore keeps its arrival time.
///
/// ## Reconnect
///
/// There is no hidden auto-reconnect. Call [connect] again and then
/// `ControllerService.start()` again, as with BLE. A daemon restart resets its
/// per-hand sequence numbers; `ControllerService.start()` rebaselines them and
/// resets `LossWindow`, so the restart is not reported as catastrophic loss.
///
/// ## Half-open sockets
///
/// A TCP peer that disappears without closing the socket (Wi-Fi lost, phone
/// asleep) leaves it writable and silent: `dart:io` reports neither an error
/// nor `done`. While a session is ready the transport sends a JSON `ping`
/// every [livenessInterval] and requires the `pong` within
/// [livenessTimeout]. A missed deadline closes the socket and reports
/// `disconnected`, which is what lets `CompositeBleTransport` fall back to
/// BLE. Probes are not FF15: their ids start at [wmrWsLivenessPingIdBase] and
/// never reach the echo sink.
class WmrWsTransport implements BleTransport {
  WmrWsTransport({
    required Iterable<WmrWsEndpoint> endpoints,
    MonotonicClock? clock,
    WmrWsConnector? connector,
    this.connectTimeout = const Duration(seconds: 10),
    this.handshakeTimeout = const Duration(seconds: 5),
    this.authTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 5),
    this.livenessInterval = const Duration(milliseconds: 500),
    this.livenessTimeout = const Duration(milliseconds: 1000),
    this.queueSize = 512,
    WmrWsDiscovery? discovery,
    bool enableDiscovery = false,
  }) : clock = clock ?? MonotonicClock(),
       _customConnector = connector,
       _discovery = discovery ?? (enableDiscovery ? WmrWsDiscovery() : null),
       _endpoints = List.unmodifiable(endpoints) {
    for (final endpoint in _endpoints) {
      final id = endpoint.resolvedDeviceId;
      if (_byDeviceId.containsKey(id)) {
        throw ArgumentError.value(
          id,
          'endpoints',
          'two endpoints resolve to the same device id',
        );
      }
      _byDeviceId[id] = endpoint;
    }
  }

  @override
  final MonotonicClock clock;

  /// Time allowed for the WebSocket upgrade and DNS/TCP connect.
  final Duration connectTimeout;

  /// Time allowed for the daemon's `hello` after the socket opens.
  final Duration handshakeTimeout;

  /// Time allowed for `auth_ok` after `hello`. Protocol 1 says five seconds.
  final Duration authTimeout;

  /// Time allowed for `subscribed`, `unsubscribed` or `status` replies.
  final Duration requestTimeout;

  /// How long after the previous `pong` the next liveness probe is sent. A
  /// non-positive duration disables the probes.
  ///
  /// A TCP peer that vanished (Wi-Fi gone, cable pulled, phone asleep) leaves
  /// the socket open and writable: no error, no close, no traffic. The daemon
  /// answers `{"type":"ping"}` with a `pong`, so a probe that is not answered
  /// proves the path is dead and the session is failed with
  /// [WmrWsLivenessException], which reports `disconnected`.
  ///
  /// Probes use ids from [wmrWsLivenessPingIdBase] upwards, so they never
  /// produce an FF15 echo answer.
  final Duration livenessInterval;

  /// How long one liveness probe may stay unanswered before the session is
  /// considered half-open. Defaults to one second, so with the default
  /// [livenessInterval] a silent peer is reported within 1500 ms.
  final Duration livenessTimeout;

  /// Client-side notification queue bound per stream, mirroring the daemon's
  /// 512-message queue. Overflow drops the newest message and is counted in
  /// [statsFor].
  final int queueSize;

  final WmrWsConnector? _customConnector;
  final WmrWsDiscovery? _discovery;
  final List<WmrWsEndpoint> _endpoints;
  final Map<String, WmrWsEndpoint> _byDeviceId = {};

  /// Endpoints yielded by the most recent discovery pass. Kept apart from
  /// [_byDeviceId] so a later scan can replace them instead of mistaking them
  /// for configured endpoints and skipping them.
  final Map<String, WmrWsEndpoint> _discovered = {};

  /// Endpoints registered after construction, for a bridge whose LAN address
  /// was learned on another transport. They are connectable but are not part
  /// of the static scan list; the caller already discovered the bridge.
  final Map<String, WmrWsEndpoint> _registered = {};

  final Map<String, _WmrWsSession> _sessions = {};
  final Map<String, BleConnectionState> _states = {};
  final Map<String, StreamController<BleConnectionState>> _stateControllers =
      {};

  bool _disposed = false;

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) async* {
    final wanted = {for (final uuid in withServices) uuid.toLowerCase()};
    if (wanted.isNotEmpty && !wanted.contains(wmrBridgeServiceUuid)) {
      return;
    }
    for (final endpoint in _endpoints) {
      yield _scanResult(endpoint);
    }
    final discovery = _discovery;
    if (discovery == null) return;
    final discovered = await discovery.discover();
    // Drop the previous pass's discoveries before merging: they are hints,
    // and a restarted scan must re-yield whatever the bridge still announces.
    for (final id in _discovered.keys) {
      if (!_registered.containsKey(id)) _byDeviceId.remove(id);
    }
    _discovered.clear();
    for (final endpoint in discovered) {
      final id = endpoint.resolvedDeviceId;
      if (_byDeviceId.containsKey(id)) continue;
      _discovered[id] = endpoint;
      _byDeviceId[id] = endpoint;
      yield _scanResult(endpoint);
    }
  }

  static BleScanResult _scanResult(WmrWsEndpoint endpoint) => BleScanResult(
    deviceId: endpoint.resolvedDeviceId,
    name: endpoint.displayName,
    // A Wi-Fi link has no RSSI in the BLE sense. Null is "not observable",
    // not a made-up number.
    rssi: null,
    serviceUuids: const [wmrBridgeServiceUuid],
  );

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    if (_disposed) throw StateError('WmrWsTransport is disposed');
    final endpoint = _endpointsFor(deviceId);
    final existing = _sessions[deviceId];
    if (existing != null && existing.isReady) return;
    if (existing != null && existing.isConnecting) {
      return existing.ready.future;
    }
    existing?.teardown();

    // A discovered bridge may answer on several interfaces. Try them in the
    // order discovery reported; only the last failure is surfaced.
    Object? lastError;
    StackTrace? lastStackTrace;
    var cancelledByCaller = false;
    for (final host in endpoint.hosts) {
      if (_disposed) {
        cancelledByCaller = true;
        break;
      }
      final candidate = endpoint.forHost(host);
      final session = _WmrWsSession(deviceId, candidate)
        // A failed attempt is not a disconnect while another host is waiting;
        // only the exhausted loop, or a failure after connect, reports one.
        ..suppressDisconnectState = true;
      _sessions[deviceId] = session;
      _setState(deviceId, BleConnectionState.connecting);

      final ready = session.ready.future;
      // The attempt may fail before this future is awaited; keep its error
      // from being reported as unhandled.
      unawaited(ready.catchError((Object _) {}));
      try {
        final socket = await _openSocket(candidate, session);
        if (_disposed ||
            session.isClosed ||
            session.isClosing ||
            session.cancelledByDisconnect ||
            !identical(_sessions[deviceId], session)) {
          unawaited(
            socket.close(1000, 'connect cancelled').catchError((Object _) {}),
          );
          throw WmrWsClosedException('connection abandoned');
        }
        session.socket = socket;
        session
          ..phase = _SessionPhase.awaitingHello
          ..configureTimeouts(auth: authTimeout, request: requestTimeout);
        session.subscription = socket.listen(
          (Object? data) => _onSocketData(session, data),
          onError: (Object error, StackTrace stackTrace) {
            _fail(session, WmrWsException('socket error', cause: error));
          },
          onDone: () => _onSocketDone(session),
          cancelOnError: false,
        );
        session.startHelloTimer(handshakeTimeout, _fail);
        await ready;
        if (_disposed ||
            session.isClosed ||
            session.isClosing ||
            session.cancelledByDisconnect ||
            !identical(_sessions[deviceId], session)) {
          session.teardown();
          throw WmrWsClosedException('connection abandoned');
        }
        session.cancelTimers();
        session.startLiveness(
          interval: livenessInterval,
          timeout: livenessTimeout,
          nowMs: () => clock.nowUs ~/ 1000,
          onTimeout: _fail,
        );
        // A later socket failure is terminal and must report `disconnected`.
        session.suppressDisconnectState = false;
        _setState(deviceId, BleConnectionState.connected);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (session.cancelledByDisconnect || _disposed) {
          cancelledByCaller = true;
        }
        session.teardown();
        if (identical(_sessions[deviceId], session)) {
          _sessions.remove(deviceId);
        }
        if (cancelledByCaller) break;
      }
    }

    if (!_disposed && !cancelledByCaller && !_sessions.containsKey(deviceId)) {
      _setState(deviceId, BleConnectionState.disconnected);
    }
    final failure = lastError;
    if (failure is WmrWsException) {
      Error.throwWithStackTrace(failure, lastStackTrace!);
    }
    throw WmrWsException(
      'could not connect to ${endpoint.uri}',
      cause: failure,
    );
  }

  @override
  Future<void> disconnect(String deviceId) async {
    final session = _sessions.remove(deviceId);
    if (session == null) {
      if (!_disposed) {
        _setState(deviceId, BleConnectionState.disconnected);
      }
      return;
    }
    session.cancelConnect();
    _setState(deviceId, BleConnectionState.disconnecting);
    await session.close();
    if (!_disposed && !_sessions.containsKey(deviceId)) {
      _setState(deviceId, BleConnectionState.disconnected);
    }
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    yield _states[deviceId] ?? BleConnectionState.disconnected;
    if (_disposed) return;
    yield* _stateController(deviceId).stream;
  }

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) async {
    final session = _requireReady(deviceId);
    final characteristics = <String>[];
    for (final entry in wmrWsStreamCharacteristics.entries) {
      if (session.helloRequired.supportsStreamNamed(entry.key)) {
        characteristics.add(entry.value);
      }
    }
    // FF15 (echo) and FF16 (version) always have a Wi-Fi equivalent. FF13
    // deliberately does not: the daemon has no calibration block.
    characteristics
      ..add(wmrBridgeEchoCharUuid)
      ..add(wmrBridgeVersionCharUuid);
    return [
      BleServiceInfo(
        uuid: wmrBridgeServiceUuid,
        characteristicUuids: List.unmodifiable(characteristics),
      ),
    ];
  }

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final session = _requireReady(deviceId);
    final service = serviceUuid.toLowerCase();
    final characteristic = characteristicUuid.toLowerCase();
    if (service != wmrBridgeServiceUuid) {
      throw WmrWsUnsupportedException(
        'the Wi-Fi bridge exposes only the FF10 service, not $serviceUuid',
      );
    }
    if (characteristic == wmrBridgeEchoCharUuid) {
      return session.openEchoSink(queueSize);
    }
    final stream = _streamForCharacteristic(characteristic);
    if (stream == null) {
      throw WmrWsUnsupportedException(
        'the Wi-Fi bridge has no stream for characteristic $characteristicUuid',
      );
    }
    return session.openPayloadSink(characteristic, stream, queueSize);
  }

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    final session = _requireReady(deviceId);
    await session.unsubscribe(characteristicUuid.toLowerCase());
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    final session = _requireReady(deviceId);
    final characteristic = characteristicUuid.toLowerCase();
    if (characteristic == wmrBridgeVersionCharUuid) {
      return Uint8List.fromList(utf8.encode(session.helloRequired.version));
    }
    if (characteristic == wmrBridgeConfigCharUuid) {
      throw WmrWsUnsupportedException(
        'FF13 calibration is not implemented by the Pi daemon '
        '(docs/PI_BRIDGE.md, "Companion app integration")',
      );
    }
    if (characteristic == wmrBridgeStreamCharUuid) {
      throw WmrWsUnsupportedException(
        'the Wi-Fi bridge has no 16-byte FF11 status value; use '
        'WmrWsTransport.status()',
      );
    }
    throw WmrWsUnsupportedException(
      'Wi-Fi bridge cannot read characteristic $characteristicUuid',
    );
  }

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    final session = _requireReady(deviceId);
    final characteristic = characteristicUuid.toLowerCase();
    if (characteristic == wmrBridgeConfigCharUuid) {
      throw WmrWsUnsupportedException(
        'FF13 calibration is not implemented by the Pi daemon '
        '(docs/PI_BRIDGE.md, "Companion app integration")',
      );
    }
    if (characteristic != wmrBridgeEchoCharUuid) {
      throw WmrWsUnsupportedException(
        'Wi-Fi bridge cannot write characteristic $characteristicUuid',
      );
    }
    if (value.length != wmrEchoRequestSize || value[0] != wmrEchoVersion) {
      throw ArgumentError.value(
        value,
        'value',
        'not a $wmrEchoRequestSize-byte FF15 echo request (version '
            '$wmrEchoVersion)',
      );
    }
    if (!session.hasEchoSink) {
      // The firmware only answers while FF15 notifications are enabled.
      return;
    }
    final pingId = ByteData.sublistView(value).getUint16(2, Endian.little);
    session.sendPing(pingId, clock.nowUs ~/ 1000);
  }

  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) async {
    final session = _requireReady(deviceId);
    return BleConnectionInfo(
      mtu: session.helloRequired.fragmentCapacity,
      // A WebSocket exposes none of these. Null means "not observable".
      rssi: null,
      connectionIntervalUs: null,
      phy: null,
    );
  }

  /// The daemon's JSON `status` (diagnostics; never at stream rate).
  Future<WmrWsStatus> status(String deviceId) =>
      _requireReady(deviceId).requestStatus().then(WmrWsStatus.fromJson);

  /// Asks the daemon to install its latest release and restart.
  ///
  /// With [preRelease] the request names the pre-release channel
  /// (`{"type":"upgrade","channel":"prerelease"}`). The channel field is only
  /// sent when the `hello` advertised both [WmrWsHello.upgradeCapable] and
  /// [WmrWsHello.upgradePreReleaseCapable]; a legacy bridge therefore gets a
  /// plain `{"type":"upgrade"}` and installs its stable release, rather than
  /// rejecting a field it does not know.
  ///
  /// The reply says whether the request was accepted ([WmrWsUpgradeState
  /// .started]) or refused ([WmrWsUpgradeState.busy] while another upgrade
  /// runs, [WmrWsUpgradeState.error] with `auth_failed` for a tokenless
  /// bridge or `unavailable` when the upgrade unit is missing). An accepted
  /// request restarts the daemon, so the caller must expect this session to
  /// drop and reconnect.
  Future<WmrWsUpgradeStatus> requestUpgrade(
    String deviceId, {
    bool preRelease = false,
  }) {
    final session = _requireReady(deviceId);
    final hello = session.helloRequired;
    return session
        .requestUpgrade(
          preRelease:
              preRelease &&
              hello.upgradeCapable &&
              hello.upgradePreReleaseCapable,
        )
        .then(WmrWsUpgradeStatus.fromJson);
  }

  /// The `hello` of the current session, or null when not connected.
  WmrWsHello? helloFor(String deviceId) => _sessions[deviceId]?.helloOrNull;

  /// Delivery counters of the current session, or all zeroes when there is
  /// none.
  WmrWsStats statsFor(String deviceId) =>
      _sessions[deviceId]?.stats ?? const WmrWsStats();

  /// Delivery counters summed over every session this transport has open.
  WmrWsStats get stats => _sessions.values
      .map((session) => session.stats)
      .fold(const WmrWsStats(), (sum, item) => sum + item);

  /// The endpoint configured for [deviceId].
  WmrWsEndpoint? endpointFor(String deviceId) => _byDeviceId[deviceId];

  /// Registers [endpoint] as a connectable target after construction.
  ///
  /// This is for a LAN address learned from another transport, such as the
  /// FF16 endpoint document a companion reads over BLE. The endpoint is
  /// available to [connect] but is not yielded by [scan]: the caller already
  /// discovered the bridge. A later discovery pass keeps the registration
  /// even when it reports the same device id.
  void registerEndpoint(WmrWsEndpoint endpoint) {
    final id = endpoint.resolvedDeviceId;
    _registered[id] = endpoint;
    _byDeviceId[id] = endpoint;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final session in sessions) {
      session.cancelConnect();
      await session.close();
    }
    for (final controller in _stateControllers.values) {
      await controller.close();
    }
    _stateControllers.clear();
  }

  /// Opens the socket, cancelling in-flight OS connect/HTTP tasks on timeout,
  /// `disconnect()`, or `dispose()`, and closing any late socket silently.
  Future<WebSocket> _openSocket(WmrWsEndpoint endpoint, _WmrWsSession session) {
    if (_disposed ||
        session.isClosed ||
        session.isClosing ||
        session.cancelledByDisconnect) {
      return Future<WebSocket>.error(
        WmrWsClosedException('connection abandoned'),
      );
    }

    final completer = Completer<WebSocket>();
    var aborted = false;
    var closeReason = 'connect timed out';

    HttpClient? client;
    ConnectionTask<Socket>? activeTask;
    late final Timer timer;

    void abort(Object error, StackTrace stackTrace, String reason) {
      if (aborted || completer.isCompleted) return;
      aborted = true;
      closeReason = reason;
      timer.cancel();
      session.onCancelConnect = null;
      activeTask?.cancel();
      client?.close(force: true);
      completer.completeError(error, stackTrace);
    }

    timer = Timer(connectTimeout, () {
      abort(
        WmrWsException(
          'no WebSocket connection to ${endpoint.uri} within '
          '${connectTimeout.inSeconds}s',
        ),
        StackTrace.current,
        'connect timed out',
      );
    });

    session.onCancelConnect = () {
      abort(
        WmrWsClosedException('connection abandoned'),
        StackTrace.current,
        'connect cancelled',
      );
    };

    final Future<WebSocket> opening;
    final customConnector = _customConnector;
    if (customConnector != null) {
      opening = customConnector(endpoint.uri);
    } else {
      final httpClient = HttpClient()..connectionTimeout = connectTimeout;
      client = httpClient;
      httpClient.connectionFactory =
          (Uri url, String? proxyHost, int? proxyPort) async {
            if (aborted) {
              throw WmrWsClosedException('connect cancelled');
            }
            final host = proxyHost ?? url.host;
            final port =
                proxyPort ??
                (url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80));
            final task = await Socket.startConnect(host, port);
            if (aborted) {
              task.cancel();
              throw WmrWsClosedException('connect cancelled');
            }
            activeTask = task;
            return task;
          };
      opening = WebSocket.connect(
        endpoint.uri.toString(),
        protocols: const [wmrWsSubprotocol],
        // The latency campaign measures the frame path. Letting
        // permessage-deflate buffer and compress would add a layer the BLE
        // path does not have.
        compression: CompressionOptions.compressionOff,
        customClient: httpClient,
      );
    }

    opening.then<void>(
      (socket) {
        timer.cancel();
        session.onCancelConnect = null;
        if (aborted ||
            _disposed ||
            session.isClosed ||
            session.isClosing ||
            session.cancelledByDisconnect) {
          client?.close(force: true);
          unawaited(socket.close(1000, closeReason).catchError((Object _) {}));
          if (!completer.isCompleted) {
            completer.completeError(
              WmrWsClosedException('connection abandoned'),
            );
          }
          return;
        }
        client?.close();
        completer.complete(socket);
      },
      onError: (Object error, StackTrace stackTrace) {
        timer.cancel();
        session.onCancelConnect = null;
        client?.close(force: true);
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    return completer.future;
  }

  WmrWsEndpoint _endpointsFor(String deviceId) {
    final endpoint = _byDeviceId[deviceId];
    if (endpoint != null) return endpoint;
    throw StateError(
      'Unknown WMR Wi-Fi endpoint $deviceId. Configured: '
      '${_byDeviceId.keys.join(', ')}',
    );
  }

  _WmrWsSession _requireReady(String deviceId) {
    final session = _sessions[deviceId];
    if (session == null || !session.isReady) {
      throw StateError('Device $deviceId is not connected');
    }
    return session;
  }

  static String? _streamForCharacteristic(String characteristic) {
    for (final entry in wmrWsStreamCharacteristics.entries) {
      if (entry.value == characteristic) return entry.key;
    }
    return null;
  }

  // ---- socket events ----------------------------------------------------

  void _onSocketData(_WmrWsSession session, Object? data) {
    // The stamp is the first thing that happens, before JSON typing, stream
    // lookup, queueing or any consumer callback. The whole latency campaign
    // depends on this line; do not move it below the dispatch logic.
    final receivedAtUs = clock.nowUs;
    if (data is List<int>) {
      session.onBinary(data, receivedAtUs);
      return;
    }
    if (data is String) {
      session.onText(data, receivedAtUs);
      return;
    }
    session.unexpectedMessages++;
  }

  void _onSocketDone(_WmrWsSession session) {
    if (session.isClosed) return;
    final closeCode = session.socket?.closeCode;
    final closeReason = session.socket?.closeReason;
    _fail(
      session,
      session.authWasPending
          ? WmrWsAuthException(
              WmrWsAuthFailure.rejected,
              'the daemon closed the socket before authentication',
              cause: closeCode,
            )
          : WmrWsClosedException(
              'the daemon closed the socket',
              closeCode: closeCode,
              closeReason: closeReason,
            ),
    );
  }

  void _fail(_WmrWsSession session, WmrWsException error) {
    if (session.isClosed) return;
    final wasCurrent = identical(_sessions[session.deviceId], session);
    session.fail(error);
    if (wasCurrent) {
      _sessions.remove(session.deviceId);
    }
    if (!session.suppressDisconnectState && wasCurrent && !_disposed) {
      _setState(session.deviceId, BleConnectionState.disconnected);
    }
  }

  void _setState(String deviceId, BleConnectionState state) {
    _states[deviceId] = state;
    final controller = _stateControllers[deviceId];
    if (controller != null && !controller.isClosed) controller.add(state);
  }

  StreamController<BleConnectionState> _stateController(String deviceId) =>
      _stateControllers.putIfAbsent(
        deviceId,
        StreamController<BleConnectionState>.broadcast,
      );
}

enum _SessionPhase { connecting, awaitingHello, awaitingAuth, ready, closed }

class _PendingControl {
  _PendingControl(this.expectedType, this.completer);

  final String expectedType;
  final Completer<Map<String, Object?>> completer;
}

class _WmrWsSession {
  _WmrWsSession(this.deviceId, this.endpoint) : ready = Completer<void>();

  final String deviceId;
  final WmrWsEndpoint endpoint;

  final Completer<void> ready;
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  WmrWsHello? hello;

  _SessionPhase phase = _SessionPhase.connecting;
  bool _closing = false;
  bool cancelledByDisconnect = false;
  void Function()? onCancelConnect;
  Timer? _helloTimer;
  Timer? _authTimer;
  _PendingControl? _pending;

  Timer? _livenessTimer;
  Timer? _livenessDeadline;
  Duration _livenessInterval = Duration.zero;
  Duration _livenessTimeout = Duration.zero;
  int _livenessSeq = 0;
  int? _livenessPendingId;
  int Function()? _livenessNowMs;
  void Function(_WmrWsSession, WmrWsException)? _livenessOnTimeout;

  /// The characteristic whose frames the socket should deliver right now.
  /// Set before the `subscribe` message is written, so frames that race the
  /// `subscribed` reply are not lost.
  String? dispatchingCharacteristic;

  /// The sink that was actually subscribed for [dispatchingCharacteristic].
  /// A newer sink may already sit in [_payloadSinks] for the same
  /// characteristic; cleanup must close the subscribed one, not the newer.
  WmrWsNotificationSink? _activeSink;

  final Map<String, WmrWsNotificationSink> _payloadSinks = {};
  WmrWsNotificationSink? _echoSink;

  Future<void> _tail = Future<void>.value();

  int payloadMessages = 0;
  int textMessages = 0;
  int droppedByQueue = 0;
  int unexpectedMessages = 0;
  int controlErrors = 0;

  bool get isReady => phase == _SessionPhase.ready && !_closing;

  bool get isConnecting =>
      !_closing &&
      (phase == _SessionPhase.connecting ||
          phase == _SessionPhase.awaitingHello ||
          phase == _SessionPhase.awaitingAuth);

  bool get isClosed => phase == _SessionPhase.closed;

  bool get isClosing => _closing;

  bool get isClosedOrClosing => isClosed || _closing;

  void cancelConnect() {
    cancelledByDisconnect = true;
    final cancel = onCancelConnect;
    onCancelConnect = null;
    cancel?.call();
  }

  /// Suppresses the `disconnected` state of a failed candidate while
  /// `connect()` still has other hosts to try.
  bool suppressDisconnectState = false;

  bool get authWasPending => phase == _SessionPhase.awaitingAuth;

  WmrWsHello? get helloOrNull => hello;

  /// The handshake completed, so [hello] exists.
  WmrWsHello get helloRequired {
    final value = hello;
    if (value == null) throw StateError('no hello for this session');
    return value;
  }

  bool get hasEchoSink => _echoSink != null && !_echoSink!.isClosed;

  WmrWsStats get stats => WmrWsStats(
    payloadMessages: payloadMessages,
    textMessages: textMessages,
    droppedByQueue: droppedByQueue,
    unexpectedMessages: unexpectedMessages,
    controlErrors: controlErrors,
  );

  void startHelloTimer(
    Duration timeout,
    void Function(_WmrWsSession, WmrWsException) onTimeout,
  ) {
    _helloTimer?.cancel();
    _helloTimer = Timer(timeout, () {
      if (isReady || isClosed) return;
      onTimeout(
        this,
        WmrWsHandshakeException(
          'the daemon sent no hello within ${timeout.inMilliseconds} ms',
        ),
      );
    });
  }

  void cancelTimers() {
    _helloTimer?.cancel();
    _helloTimer = null;
    _authTimer?.cancel();
    _authTimer = null;
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _livenessDeadline?.cancel();
    _livenessDeadline = null;
    _livenessPendingId = null;
  }

  /// Starts the half-open detector: one probe at a time, each answered by a
  /// `pong` within [timeout]. A non-positive [interval] or [timeout] leaves it
  /// off.
  void startLiveness({
    required Duration interval,
    required Duration timeout,
    required int Function() nowMs,
    required void Function(_WmrWsSession, WmrWsException) onTimeout,
  }) {
    if (interval <= Duration.zero || timeout <= Duration.zero) return;
    _livenessInterval = interval;
    _livenessTimeout = timeout;
    _livenessNowMs = nowMs;
    _livenessOnTimeout = onTimeout;
    _scheduleLivenessProbe();
  }

  void _scheduleLivenessProbe() {
    if (isClosed || _livenessInterval <= Duration.zero) return;
    _livenessTimer?.cancel();
    _livenessTimer = Timer(_livenessInterval, _sendLivenessProbe);
  }

  void _sendLivenessProbe() {
    if (isClosed || !isReady) return;
    final id = wmrWsLivenessPingIdBase + ++_livenessSeq;
    _livenessPendingId = id;
    _livenessDeadline?.cancel();
    _livenessDeadline = Timer(_livenessTimeout, () {
      if (isClosed || !isReady) return;
      _livenessDeadline = null;
      _livenessPendingId = null;
      _livenessOnTimeout?.call(
        this,
        WmrWsLivenessException(
          'no pong within ${_livenessTimeout.inMilliseconds} ms: the TCP peer '
          'is silent',
        ),
      );
    });
    _sendJson({'type': 'ping', 'id': id, 't': _livenessNowMs?.call() ?? 0});
  }

  void _onLivenessPong(int id) {
    if (isClosed || !isReady || id != _livenessPendingId) return;
    _livenessPendingId = null;
    _livenessDeadline?.cancel();
    _livenessDeadline = null;
    _scheduleLivenessProbe();
  }

  // ---- handshake --------------------------------------------------------

  void onText(String text, int receivedAtUs) {
    textMessages++;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      unexpectedMessages++;
      if (!ready.isCompleted) {
        _completeReadyError(
          WmrWsHandshakeException(
            'malformed JSON from the daemon',
            cause: error,
          ),
        );
      }
      return;
    }
    if (decoded is! Map<String, Object?>) {
      unexpectedMessages++;
      return;
    }
    switch (decoded['type']) {
      case 'hello':
        try {
          _onHello(decoded);
        } on WmrWsException catch (error) {
          _completeReadyError(error);
        }
      case 'auth_ok':
        _onAuthOk();
      case 'error':
        _onError(decoded);
      case 'subscribed':
        _onControlReply('subscribed', decoded);
      case 'unsubscribed':
        _onControlReply('unsubscribed', decoded);
      case 'status':
        _onControlReply('status', decoded);
      case 'upgrade_status':
        _onControlReply('upgrade_status', decoded);
      case 'pong':
        _onPong(decoded, receivedAtUs);
      default:
        unexpectedMessages++;
    }
  }

  void _onHello(Map<String, Object?> json) {
    if (isClosed) return;
    final parsed = WmrWsHello.fromJson(json);
    final expectedBridgeId = endpoint.bridgeId;
    if (expectedBridgeId != null &&
        expectedBridgeId.isNotEmpty &&
        parsed.bridgeId != expectedBridgeId) {
      _completeReadyError(
        WmrWsHandshakeException(
          'bridge id mismatch: ${endpoint.uri} was discovered as '
          '"$expectedBridgeId" but its hello reports '
          '"${parsed.bridgeId}"',
        ),
      );
      return;
    }
    hello = parsed;
    if (phase == _SessionPhase.awaitingHello) {
      _helloTimer?.cancel();
      _helloTimer = null;
      if (parsed.authRequired) {
        final token = endpoint.token;
        if (token == null) {
          _completeReadyError(
            const WmrWsAuthException(
              WmrWsAuthFailure.noToken,
              'the daemon requires a token but the endpoint has none',
            ),
          );
          return;
        }
        phase = _SessionPhase.awaitingAuth;
        _authTimer?.cancel();
        _authTimer = Timer(_authTimeout, () {
          _completeReadyError(
            WmrWsAuthException(
              WmrWsAuthFailure.timeout,
              'no auth_ok within the auth timeout',
            ),
          );
        });
        _sendJson({'type': 'auth', 'token': token});
      } else {
        _completeReady();
      }
    }
  }

  /// The transport's auth timeout, copied here so the session timer does not
  /// reach back into the transport.
  Duration _authTimeout = const Duration(seconds: 5);

  /// The transport's control-reply timeout.
  Duration _requestTimeout = const Duration(seconds: 5);

  void configureTimeouts({required Duration auth, required Duration request}) {
    _authTimeout = auth;
    _requestTimeout = request;
  }

  void _onAuthOk() {
    if (phase != _SessionPhase.awaitingAuth || isClosed) return;
    _authTimer?.cancel();
    _authTimer = null;
    _completeReady();
  }

  void _completeReady() {
    if (isClosed) return;
    phase = _SessionPhase.ready;
    cancelTimers();
    if (!ready.isCompleted) ready.complete();
  }

  void _completeReadyError(WmrWsException error) {
    if (ready.isCompleted) return;
    ready.completeError(error);
  }

  // ---- control messages -------------------------------------------------

  void _onError(Map<String, Object?> json) {
    final code = json['code'] is String ? json['code']! as String : 'unknown';
    final message = json['message'] is String
        ? json['message']! as String
        : 'the daemon reported $code';
    if (code == 'auth_failed') {
      _completeReadyError(
        WmrWsAuthException(WmrWsAuthFailure.rejected, message),
      );
      return;
    }
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      pending.completer.completeError(WmrWsControlException(code, message));
    } else {
      controlErrors++;
    }
  }

  void _onControlReply(String type, Map<String, Object?> json) {
    final pending = _pending;
    if (pending == null || pending.expectedType != type) {
      unexpectedMessages++;
      return;
    }
    _pending = null;
    pending.completer.complete(json);
  }

  void _onPong(Map<String, Object?> json, int receivedAtUs) {
    final id = json['id'];
    if (id is! num) {
      unexpectedMessages++;
      return;
    }
    final pingId = id.toInt();
    if (pingId >= wmrWsLivenessPingIdBase) {
      // The transport's own keepalive. Never synthesize an echo answer for
      // it: the FF15 sink belongs to the app's echo client.
      _onLivenessPong(pingId);
      return;
    }
    final serverTimeUs = json['serverTimeUs'];
    final sink = _echoSink;
    if (serverTimeUs is! num) {
      unexpectedMessages++;
      return;
    }
    if (sink == null || sink.isClosed) return;
    // FF15 on Wi-Fi: the JSON pong carries no server-side turnaround or queue
    // depth, so those are 0 and rxTimeUs is the daemon's reply clock.
    // EchoSample.rttUs then equals end-to-end minus nothing, which is the
    // round trip the client can actually observe.
    final answer = EchoAnswer(
      pingId: pingId & 0xffff,
      rxTimeUs: serverTimeUs.toInt(),
      turnaroundUs: 0,
      queueDepth: 0,
    );
    sink.add(
      BleNotification(
        value: encodeEchoAnswer(answer),
        receivedAtUs: receivedAtUs,
      ),
    );
  }

  void sendPing(int pingId, int nowMs) {
    _sendJson({'type': 'ping', 'id': pingId & 0xffff, 't': nowMs});
  }

  Future<Map<String, Object?>> requestStatus() =>
      _enqueue(() => _request({'type': 'status'}, 'status'));

  Future<Map<String, Object?>> requestUpgrade({bool preRelease = false}) =>
      _enqueue(
        () => _request({
          'type': 'upgrade',
          if (preRelease) 'channel': 'prerelease',
        }, 'upgrade_status'),
      );

  Future<Map<String, Object?>> _request(
    Map<String, Object?> message,
    String expectedType,
  ) {
    if (!isReady || isClosedOrClosing) {
      return Future<Map<String, Object?>>.error(
        WmrWsClosedException('the socket is not connected'),
      );
    }
    if (_pending != null) {
      return Future<Map<String, Object?>>.error(
        StateError('a control request is already waiting'),
      );
    }
    final completer = Completer<Map<String, Object?>>();
    _pending = _PendingControl(expectedType, completer);
    _sendJson(message);
    return completer.future.timeout(
      _requestTimeout,
      onTimeout: () {
        if (identical(_pending?.completer, completer)) _pending = null;
        throw WmrWsException(
          'timed out waiting for the daemon to reply with $expectedType',
        );
      },
    );
  }

  void _sendJson(Map<String, Object?> message) {
    final socket = this.socket;
    if (socket == null ||
        isClosedOrClosing ||
        socket.readyState != WebSocket.open) {
      return;
    }
    socket.add(jsonEncode(message));
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  // ---- streams ----------------------------------------------------------

  Stream<BleNotification> openEchoSink(int capacity) {
    final existing = _echoSink;
    if (existing != null && !existing.isClosed && existing.hasListeners) {
      return existing.stream;
    }
    existing?.close();
    final sink = WmrWsNotificationSink(capacity: capacity);
    _echoSink = sink;
    return sink.stream;
  }

  Stream<BleNotification> openPayloadSink(
    String characteristic,
    String stream,
    int capacity,
  ) {
    final existing = _payloadSinks[characteristic];
    if (existing != null && !existing.isClosed && existing.hasListeners) {
      return existing.stream;
    }
    existing?.close();
    final sink = WmrWsNotificationSink(capacity: capacity);
    _payloadSinks[characteristic] = sink;

    unawaited(
      _enqueue(() async {
        if (isClosedOrClosing) {
          if (identical(_payloadSinks[characteristic], sink)) {
            _payloadSinks.remove(characteristic);
          }
          sink.close();
          return;
        }
        try {
          // The daemon allows one payload stream per connection. Switching
          // means `unsubscribe` first, exactly like zeroing the old CCC.
          final active = dispatchingCharacteristic;
          if (active != null && active != characteristic) {
            final previous = _activeSink;
            try {
              // Keep the old stream dispatching until the daemon confirms, so
              // frames already in the socket are not lost.
              await _request({'type': 'unsubscribe'}, 'unsubscribed');
            } finally {
              // A newer subscribe may already have replaced this sink for the
              // same characteristic. Close only the sink that was subscribed;
              // the newer one is handled by its own queued operation.
              if (identical(_payloadSinks[active], previous)) {
                _payloadSinks.remove(active);
              }
              previous?.close();
              if (dispatchingCharacteristic == active) {
                dispatchingCharacteristic = null;
                _activeSink = null;
              }
            }
          }
          if (_payloadSinks[characteristic] != sink || isClosedOrClosing) {
            if (identical(_payloadSinks[characteristic], sink)) {
              _payloadSinks.remove(characteristic);
            }
            sink.close();
            return;
          }
          // Set before writing so frames racing the reply are routed.
          dispatchingCharacteristic = characteristic;
          _activeSink = sink;
          await _request({'type': 'subscribe', 'stream': stream}, 'subscribed');
        } catch (error) {
          if (identical(_payloadSinks[characteristic], sink)) {
            _payloadSinks.remove(characteristic);
          }
          if (dispatchingCharacteristic == characteristic) {
            dispatchingCharacteristic = null;
            _activeSink = null;
          }
          if (!isClosedOrClosing) {
            sink.addError(_streamFault(characteristic, error));
          }
          sink.close();
        }
      }),
    );
    return sink.stream;
  }

  Future<void> unsubscribe(String characteristic) {
    final expected = _payloadSinks[characteristic];
    return _enqueue(() async {
      if (characteristic == wmrBridgeEchoCharUuid) {
        final echo = _echoSink;
        _echoSink = null;
        echo?.close();
        return;
      }
      final subscribed = identical(dispatchingCharacteristic, characteristic)
          ? _activeSink
          : expected;
      if (dispatchingCharacteristic == characteristic) {
        if (!isClosedOrClosing) {
          try {
            // Keep dispatching until the daemon confirms: frames already in the
            // socket before this message are real payloads, not strays.
            await _request({'type': 'unsubscribe'}, 'unsubscribed');
          } catch (_) {
            // The daemon may already have cleared it; local state is what we
            // control, and it is cleared below.
          }
        }
        if (dispatchingCharacteristic == characteristic) {
          dispatchingCharacteristic = null;
          _activeSink = null;
        }
      }
      // A subscribe for the same characteristic may have replaced the sink
      // while this operation waited its turn; leave that newer sink alone.
      if (identical(_payloadSinks[characteristic], subscribed)) {
        _payloadSinks.remove(characteristic);
      }
      subscribed?.close();
    });
  }

  static BleStreamException _streamFault(String characteristic, Object error) {
    if (error is WmrWsControlException) {
      switch (error.code) {
        case 'stream_active':
          return BleStreamException(
            BleStreamFaultKind.otherStreamActive,
            characteristic,
            'the daemon says another stream is active: ${error.message}',
          );
        default:
          return BleStreamException(
            BleStreamFaultKind.enableFailed,
            characteristic,
            '${error.code}: ${error.message}',
          );
      }
    }
    return BleStreamException(
      BleStreamFaultKind.enableFailed,
      characteristic,
      '$error',
    );
  }

  // ---- data -------------------------------------------------------------

  void onBinary(List<int> data, int receivedAtUs) {
    payloadMessages++;
    final characteristic = dispatchingCharacteristic;
    final sink = characteristic == null ? null : _payloadSinks[characteristic];
    if (sink == null || sink.isClosed) {
      unexpectedMessages++;
      return;
    }
    final value = data is Uint8List ? data : Uint8List.fromList(data);
    if (!sink.add(BleNotification(value: value, receivedAtUs: receivedAtUs))) {
      droppedByQueue++;
    }
  }

  // ---- lifecycle --------------------------------------------------------

  void fail(WmrWsException error) {
    if (isClosed) return;
    cancelTimers();
    phase = _SessionPhase.closed;
    if (!ready.isCompleted) ready.completeError(error);
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(error);
    }
    for (final sink in _payloadSinks.values) {
      sink.close();
    }
    _payloadSinks.clear();
    _echoSink?.close();
    _echoSink = null;
    dispatchingCharacteristic = null;
    _activeSink = null;
    unawaited(subscription?.cancel());
    subscription = null;
    final ws = socket;
    socket = null;
    if (ws != null && ws.readyState != WebSocket.closed) {
      // Best effort: the daemon also reaps dead clients.
      unawaited(ws.close(1000, 'client gave up').catchError((Object _) {}));
    }
  }

  Future<void> close() async {
    cancelConnect();
    if (isClosed || _closing) return;
    _closing = true;
    cancelTimers();
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(
        WmrWsClosedException('the client closed the socket'),
      );
    }
    final ws = socket;
    if (ws != null && ws.readyState == WebSocket.open) {
      try {
        ws.add(jsonEncode({'type': 'close'}));
        await ws
            .close(1000, 'client closed')
            .timeout(const Duration(milliseconds: 250), onTimeout: () {});
      } catch (_) {
        // Closing is best effort; the daemon also reaps dead clients.
      }
    }
    fail(WmrWsClosedException('the client closed the socket'));
  }

  void teardown() {
    if (isClosed) return;
    fail(WmrWsClosedException('connection abandoned'));
  }
}
