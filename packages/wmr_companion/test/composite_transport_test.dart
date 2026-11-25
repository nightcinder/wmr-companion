import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_ws/wmr_ws.dart';

const _tcpDeviceId = 'tcp-1';
const _bleDeviceId = 'ble-1';
const _bridgeId = 'pi-1';
const _lanDeviceId = '127.0.0.1:8765';

Future<void> _settle([int millis = 20]) =>
    Future<void>.delayed(Duration(milliseconds: millis));

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Uint8List _endpointDocument({
  String bridgeId = _bridgeId,
  List<String> hosts = const ['127.0.0.1'],
  int port = 8765,
  bool authRequired = false,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'type': 'wmr_ble_endpoint',
      'protocol': 1,
      'bridge_id': bridgeId,
      'name': 'WMR Bridge',
      'version': '0.2.4',
      'hosts': hosts,
      'port': port,
      'path': '/wmr',
      'authRequired': authRequired,
    }),
  ),
);

Uint8List _sessionToken([String token = 'secret']) => Uint8List.fromList(
  utf8.encode(jsonEncode({'type': 'wmr_ble_session', 'token': token})),
);

Uint8List _versionString([String value = '0.2.4-pi']) =>
    Uint8List.fromList(utf8.encode(value));

/// The timeline keys `CompositeBleTransport.linkTimelineFor` records, the
/// same ones the app's Debug row reads and the diagnostics bundle carries:
/// one `<mark>_us` per step, the live episode's frozen anchor, plus the
/// finished-episode list.
const _timelineKeys = [
  'last_tcp_record_us',
  'stall_detected_us',
  'failover_begin_us',
  'failover_end_us',
  'first_ble_record_us',
  'upgrade_dial_start_us',
  'upgrade_dial_end_us',
  'first_upgrade_dial_start_us',
  'upgrade_dial_attempts',
  'first_tcp_record_us',
  'first_tcp_record_session',
  'first_tcp_record_wall_us',
  'episode_last_tcp_record_us',
  'failover_outcome',
  'failover_reason',
  'failover_candidate_count',
  'upgrade_outcome',
  'upgrade_candidate_count',
  'recovery_lane',
  'recovery_us',
  'episodes',
];

class _FakeTcp extends WmrWsTransport {
  _FakeTcp() : super(endpoints: const []);

  final List<BleScanResult> scanResults = [];
  final Map<String, WmrWsEndpoint> endpoints = {};
  final Map<String, WmrWsHello> hellos = {};
  final Map<String, BleConnectionState> states = {};
  final Map<String, StreamController<BleConnectionState>> stateControllers = {};
  final Map<String, StreamController<BleNotification>> streams = {};
  final List<String> connectCalls = [];
  final List<String> unsubscribeCalls = [];
  final List<String> tcpDisconnects = [];
  bool failConnect = false;

  /// When set, cancelling a notification subscription throws, like a stack
  /// that fails the release of a channel during a lane switch.
  bool failCancel = false;

  /// When set, the first [connectionState] subscription reports the leg as
  /// already lost, like a stall that lands between the dial and the switch
  /// that names TCP active.
  bool dropOnWatch = false;

  /// When true, [connect] never answers, like a LAN address that no longer
  /// exists: the socket attempt runs until the transport's own timeout.
  bool hangConnect = false;
  bool _disposed = false;

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      Stream.fromIterable(scanResults);

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    connectCalls.add(deviceId);
    if (hangConnect) await Completer<void>().future;
    if (failConnect) throw StateError('tcp down');
    final endpoint = endpoints[deviceId];
    if (endpoint == null) throw StateError('unknown endpoint $deviceId');
    hellos[deviceId] ??= _hello(endpoint.bridgeId ?? _bridgeId);
    _setState(deviceId, BleConnectionState.connected);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    tcpDisconnects.add(deviceId);
    _setState(deviceId, BleConnectionState.disconnected);
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    if (dropOnWatch) {
      dropOnWatch = false;
      yield BleConnectionState.disconnected;
    } else {
      yield states[deviceId] ?? BleConnectionState.disconnected;
    }
    if (_disposed) return;
    yield* _stateController(deviceId).stream;
  }

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) async =>
      fakeBridgeDeviceServices;

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final source = _stream(deviceId, characteristicUuid).stream;
    if (!failCancel) return source;
    final releasing = StreamController<BleNotification>(
      onCancel: () => Future<void>.error(StateError('tcp unsubscribe failed')),
    );
    source.listen(releasing.add, onError: releasing.addError);
    return releasing.stream;
  }

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    unsubscribeCalls.add(characteristicUuid.toLowerCase());
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async => Uint8List(0);

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {}

  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) async =>
      const BleConnectionInfo(mtu: 244, rssi: -40);

  @override
  WmrWsHello? helloFor(String deviceId) => hellos[deviceId];

  @override
  WmrWsEndpoint? endpointFor(String deviceId) => endpoints[deviceId];

  @override
  void registerEndpoint(WmrWsEndpoint endpoint) {
    endpoints[endpoint.resolvedDeviceId] = endpoint;
    hellos[endpoint.resolvedDeviceId] ??= _hello(
      endpoint.bridgeId ?? _bridgeId,
    );
  }

  bool emit(
    String deviceId,
    String characteristicUuid,
    List<int> value, {
    int? receivedAtUs,
  }) {
    final controller = streams[_key(deviceId, characteristicUuid)];
    if (controller == null || !controller.hasListener) return false;
    controller.add(
      BleNotification(
        value: Uint8List.fromList(value),
        receivedAtUs: receivedAtUs ?? clock.nowUs,
      ),
    );
    return true;
  }

  void drop(String deviceId) {
    _setState(deviceId, BleConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final controller in stateControllers.values) {
      await controller.close();
    }
    for (final controller in streams.values) {
      await controller.close();
    }
    stateControllers.clear();
    streams.clear();
  }

  static WmrWsHello _hello(String bridgeId) => WmrWsHello(
    protocol: 1,
    transport: 'wifi',
    device: 'wmr-pi',
    version: '0.2.4',
    hostname: 'pi',
    bridgeId: bridgeId,
    authRequired: false,
    streams: const {'raw', 'decoded', 'batched'},
    recordSize: 56,
    batchMax: 9,
    fragmentCapacity: 244,
  );

  StreamController<BleConnectionState> _stateController(String deviceId) =>
      stateControllers.putIfAbsent(
        deviceId,
        () => StreamController<BleConnectionState>.broadcast(),
      );

  StreamController<BleNotification> _stream(
    String deviceId,
    String characteristicUuid,
  ) => streams.putIfAbsent(
    _key(deviceId, characteristicUuid),
    () => StreamController<BleNotification>.broadcast(),
  );

  void _setState(String deviceId, BleConnectionState state) {
    states[deviceId] = state;
    _stateController(deviceId).add(state);
  }

  static String _key(String deviceId, String characteristicUuid) =>
      '$deviceId|${characteristicUuid.toLowerCase()}';
}

/// A BLE fake whose scan emits nothing until [finishScan], so the composite's
/// connect path deterministically reaches its wait for a scan hit.
class _GatedScanBle extends FakeTransport {
  _GatedScanBle({required super.devices, required this.results});

  final List<BleScanResult> results;
  final StreamController<BleScanResult> _scan =
      StreamController<BleScanResult>();

  void finishScan() {
    if (_scan.isClosed) return;
    results.forEach(_scan.add);
    unawaited(_scan.close());
  }

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      _scan.stream;
}

/// A BLE fake whose [connect] blocks until [gate] completes, so a test can
/// hold a failover in its `switching` window.
class _GatedConnectBle extends FakeTransport {
  _GatedConnectBle({required super.devices});

  final Completer<void> gate = Completer<void>();
  final List<String> connectCalls = [];

  @override
  Future<void> connect(String deviceId) async {
    connectCalls.add(deviceId);
    await gate.future;
    await super.connect(deviceId);
  }
}

/// A BLE fake whose connection-state stream defers cancellation until
/// [cancelGate] completes, like a transport that parks its generator over a
/// delivery turn.
class _StuckCancelBle extends FakeTransport {
  _StuckCancelBle({required super.devices});

  final Completer<void> cancelGate = Completer<void>();
  final Map<String, StreamController<BleConnectionState>> _unsolicited = {};

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    yield BleConnectionState.connected;
    yield* _unsolicited
        .putIfAbsent(
          deviceId,
          () => StreamController<BleConnectionState>(
            onCancel: () => cancelGate.future,
          ),
        )
        .stream;
  }
}

/// A TCP fake that hands every concurrent caller the same in-flight dial, like
/// [WmrWsTransport.connect] joining an existing session, and holds it until
/// [release] so a test can land a dial after its probe budget expired.
///
/// Like the real transport, [disconnect] tears the in-flight session down: the
/// next [connect] dials fresh instead of joining the abandoned one.
class _HeldDialTcp extends _FakeTcp {
  final Completer<void> release = Completer<void>();
  final List<String> disconnectCalls = [];
  Future<void>? _pending;
  int dialAttempts = 0;
  int freshDials = 0;
  int joins = 0;

  @override
  Future<void> connect(String deviceId) {
    dialAttempts++;
    final pending = _pending;
    if (pending != null) {
      joins++;
      return pending;
    }
    freshDials++;
    final dial = _dial(deviceId);
    _pending = dial;
    return dial;
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnectCalls.add(deviceId);
    _pending = null;
    return super.disconnect(deviceId);
  }

  Future<void> _dial(String deviceId) async {
    await release.future;
    await super.connect(deviceId);
  }
}

/// A TCP fake that joins each candidate's in-flight dial and holds it until the
/// test releases that candidate, so two candidates can be in flight at once.
class _JoiningTcp extends _FakeTcp {
  final Map<String, Completer<void>> holds = {};
  final Map<String, Future<void>> _pending = {};
  final List<String> dials = [];
  final List<String> disconnectCalls = [];
  int freshDials = 0;
  int joins = 0;

  /// Holds every dial for [id] until the returned completer completes.
  Completer<void> hold(String id) => holds.putIfAbsent(id, Completer.new);

  @override
  Future<void> connect(String deviceId) {
    dials.add(deviceId);
    final pending = _pending[deviceId];
    if (pending != null) {
      joins++;
      return pending;
    }
    freshDials++;
    return _pending[deviceId] ??= _dial(deviceId);
  }

  Future<void> _dial(String deviceId) async {
    final hold = holds[deviceId];
    if (hold != null) await hold.future;
    await super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnectCalls.add(deviceId);
    // A disconnect tears the session down, like WmrWsTransport removing it:
    // the next dial for this candidate starts fresh instead of joining.
    _pending.remove(deviceId);
    return super.disconnect(deviceId);
  }

  @override
  void drop(String deviceId) {
    // A dropped socket's session is gone the same way: the next dial for
    // this candidate starts fresh instead of joining the dead session's
    // dial.
    _pending.remove(deviceId);
    super.drop(deviceId);
  }
}

/// A TCP fake whose dials can be held open, so a test can land a probe after
/// the route has moved on.
class _HoldableTcp extends _FakeTcp {
  Completer<void>? holdDials;
  int heldDials = 0;
  final List<String> disconnectCalls = [];

  @override
  Future<void> connect(String deviceId) async {
    final hold = holdDials;
    if (hold != null) {
      heldDials++;
      await hold.future;
    }
    await super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnectCalls.add(deviceId);
    return super.disconnect(deviceId);
  }
}

/// A BLE fake that can refuse GATT connects for chosen devices and records
/// every disconnect.
class _RecordingBle extends FakeTransport {
  _RecordingBle({required super.devices});

  final Set<String> refusedConnects = {};
  final List<String> disconnectCalls = [];

  @override
  Future<void> connect(String deviceId) async {
    if (refusedConnects.contains(deviceId)) {
      throw StateError('ble connect refused');
    }
    await super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnectCalls.add(deviceId);
    return super.disconnect(deviceId);
  }
}

/// A TCP fake that parks the dials of chosen candidates — a LAN address whose
/// port never answers — while every other candidate lands at once, recording
/// when each dial started and when its socket was closed so a test can bound
/// how long one candidate held the attempt.
class _RefusingTcp extends _FakeTcp {
  _RefusingTcp(this.refusing);

  /// Candidates whose [connect] never completes.
  final Set<String> refusing;

  final Stopwatch _clock = Stopwatch()..start();

  /// When each dial started, in dial order: the candidate id with the
  /// stopwatch reading in microseconds.
  final List<MapEntry<String, int>> dialAt = [];

  /// When each candidate's socket was first closed, in the same units.
  final Map<String, int> closedAt = {};

  @override
  Future<void> connect(String deviceId) {
    dialAt.add(MapEntry(deviceId, _clock.elapsedMicroseconds));
    if (!refusing.contains(deviceId)) return super.connect(deviceId);
    return Completer<void>().future;
  }

  @override
  Future<void> disconnect(String deviceId) {
    closedAt.putIfAbsent(deviceId, () => _clock.elapsedMicroseconds);
    return super.disconnect(deviceId);
  }
}

/// A TCP fake that answers each dial only after a delay — a handshake on
/// congested Wi-Fi — so a test can prove the last candidate keeps the whole
/// remaining budget rather than the per-candidate cap.
class _SlowDialTcp extends _FakeTcp {
  _SlowDialTcp(this.delay);

  /// How long every [connect] takes to answer.
  final Duration delay;

  @override
  Future<void> connect(String deviceId) async {
    await Future<void>.delayed(delay);
    await super.connect(deviceId);
  }
}

/// A TCP fake whose port answers until it goes dark, then parks or refuses
/// every dial until it comes back up — a bridge whose LAN listener is gone —
/// recording when each dial started and when each parked dial's socket was
/// closed, so a test can bound a failed attempt and prove none leaked its
/// socket.
class _DarkPortTcp extends _FakeTcp {
  _DarkPortTcp({this.hang = true});

  /// Whether a dark dial hangs — a firewall dropping the SYN — instead of
  /// being refused at once — a port that is not up yet.
  final bool hang;

  bool _dark = false;

  /// A chosen stopwatch reading (µs): a dial that starts before it fails
  /// even though [goDark] was called, and one that starts at or after it
  /// answers as if the port had come back. Null keeps the port dark until
  /// [comeUp].
  int? failUntilUs;

  final Stopwatch _clock = Stopwatch()..start();

  /// The fake's stopwatch reading now, in the same units as [dialAt].
  int get nowUs => _clock.elapsedMicroseconds;

  /// Stopwatch reading (µs) when each dial started, oldest first.
  final List<int> dialAt = [];

  /// Stopwatch reading (µs) when each parked dial's socket was closed,
  /// oldest first. Only a dial still in flight counts, so a probe teardown
  /// lands here and a stalled leg's own close does not.
  final List<int> closedAt = [];

  /// Index into [dialAt] of the first dial made after the port went dark.
  int darkFrom = 0;

  final Set<String> _inFlight = {};

  /// The port stops answering: every later dial fails until [comeUp] (or
  /// past [failUntilUs]).
  void goDark() {
    _dark = true;
    failUntilUs = null;
    darkFrom = dialAt.length;
  }

  /// The port answers again: the next dial lands at once.
  void comeUp() => _dark = false;

  @override
  Future<void> connect(String deviceId) async {
    final startedAt = _clock.elapsedMicroseconds;
    dialAt.add(startedAt);
    final until = failUntilUs;
    final dark = _dark && (until == null || startedAt < until);
    if (!dark) {
      await super.connect(deviceId);
      return;
    }
    if (!hang) throw StateError('connection refused');
    _inFlight.add(deviceId);
    await Completer<void>().future;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    if (_inFlight.remove(deviceId)) {
      closedAt.add(_clock.elapsedMicroseconds);
    }
    await super.disconnect(deviceId);
  }
}

/// A TCP fake that holds every dial on its own completer, so a test can land
/// one dial while another (started later on the same candidate) keeps running
/// into its own budget.
class _SplitDialTcp extends _FakeTcp {
  bool holdDials = false;
  final List<Completer<void>> holds = [];
  final List<String> disconnectCalls = [];

  @override
  Future<void> connect(String deviceId) async {
    if (holdDials) {
      final hold = Completer<void>();
      holds.add(hold);
      await hold.future;
    }
    await super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnectCalls.add(deviceId);
    return super.disconnect(deviceId);
  }
}

/// A BLE fake whose [unsubscribe] logs the CCCD off but leaves the open
/// subscriptions alone, like a transport that stops notifications without
/// tearing down the stream a caller still holds.
class _CccdBle extends FakeTransport {
  _CccdBle({required super.devices});

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    cccLog.add('off ${characteristicUuid.toLowerCase()}');
  }
}

/// A BLE fake that reports the TCP leg lost from inside the BLE-notify
/// disable a switch onto TCP runs: the loss lands while that switch still
/// holds the route, so the composite remembers it instead of recording a
/// fresh stall.
class _DroppingBle extends FakeTransport {
  _DroppingBle({required super.devices, required this.onUnsubscribe});

  final void Function()? onUnsubscribe;

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    onUnsubscribe?.call();
  }
}

/// A BLE fake whose notification subscription for [characteristic] refuses to
/// cancel, like a platform stack that fails a GATT release mid-switch: the
/// detach step of a lane switch throws, so the activation fails partway.
class _StuckDetachBle extends FakeTransport {
  _StuckDetachBle({required super.devices, required this.characteristic});

  final String characteristic;

  /// Fails the cancel of every [characteristic] subscription opened while
  /// set. Clear it before the teardown so cancels there succeed.
  bool failCancel = false;

  /// One controller per [subscribe] call on [characteristic]; a cancel
  /// failed, so the listener a channel left on an older one stays until the
  /// transport reaps it.
  final List<StreamController<BleNotification>> stuckSubs = [];

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    if (characteristicUuid.toLowerCase() == characteristic) {
      final controller = StreamController<BleNotification>(
        onCancel: () {
          if (failCancel) throw StateError('unsubscribe failed');
        },
      );
      stuckSubs.add(controller);
      return controller.stream;
    }
    return super.subscribe(deviceId, serviceUuid, characteristicUuid);
  }

  /// Delivers [value] on the newest stuck subscription. Returns false when no
  /// channel is attached to it.
  bool deliverStuck(List<int> value) {
    if (stuckSubs.isEmpty) return false;
    final controller = stuckSubs.last;
    if (!controller.hasListener) return false;
    controller.add(
      BleNotification(
        value: Uint8List.fromList(value),
        receivedAtUs: clock.nowUs,
      ),
    );
    return true;
  }
}

/// A BLE fake for a lane switch that fails after an echo handoff: the cancel
/// of every [failCharacteristic] subscription throws while [failCancel] is
/// set, like a platform stack that fails a GATT release mid-switch, and every
/// [trackCharacteristic] subscription is its own controller whose
/// cancellation is counted, so a test can prove a handed-off drain
/// subscription is released instead of orphaned beside the re-attach.
class _FailingSwitchBle extends FakeTransport {
  _FailingSwitchBle({
    required super.devices,
    required this.failCharacteristic,
    required this.trackCharacteristic,
  });

  final String failCharacteristic;
  final String trackCharacteristic;

  /// Fails the cancel of every [failCharacteristic] subscription opened
  /// while set. Clear it before the teardown so cancels there succeed.
  bool failCancel = false;

  /// One controller per [subscribe] call on [trackCharacteristic], newest
  /// last, so the channel a rollback re-attached is the delivery target.
  final List<StreamController<BleNotification>> tracked = [];
  int cancelledSubscriptions = 0;

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final normalized = characteristicUuid.toLowerCase();
    if (normalized == failCharacteristic) {
      return StreamController<BleNotification>(
        onCancel: () {
          if (failCancel) throw StateError('unsubscribe failed');
        },
      ).stream;
    }
    if (normalized == trackCharacteristic) {
      final controller = StreamController<BleNotification>(
        onCancel: () => cancelledSubscriptions++,
      );
      tracked.add(controller);
      return controller.stream;
    }
    return super.subscribe(deviceId, serviceUuid, characteristicUuid);
  }

  /// Delivers [value] on the newest tracked subscription. Returns false when
  /// no channel is attached to it.
  bool deliverTracked(List<int> value) {
    if (tracked.isEmpty) return false;
    final controller = tracked.last;
    if (!controller.hasListener) return false;
    controller.add(
      BleNotification(
        value: Uint8List.fromList(value),
        receivedAtUs: clock.nowUs,
      ),
    );
    return true;
  }
}

/// A loopback WebSocket daemon that says `hello` and answers liveness
/// `ping`s on a configurable delay — or stops answering, like a Pi whose TCP
/// peer vanished while the socket stayed open.
class _LoopbackPi {
  _LoopbackPi._(this._server);

  final HttpServer _server;
  bool _stopped = false;

  /// Replies to liveness `ping`s unless cleared. A test that clears it
  /// models a half-open TCP peer: the socket stays open and writable, but
  /// nothing behind it answers.
  bool answerPings = true;

  /// How long each `ping` waits for its `pong`, like a loaded Pi that still
  /// answers inside the deadline.
  Duration pongDelay = Duration.zero;

  /// Wall-clock time of each `pong` sent, oldest first.
  final List<DateTime> pongAt = [];

  int get port => _server.port;

  static Future<_LoopbackPi> start({required String bridgeId}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pi = _LoopbackPi._(server);
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (protocols) =>
            protocols.contains('wmr-wifi-v1') ? 'wmr-wifi-v1' : null,
        compression: CompressionOptions.compressionOff,
      );
      // Keep reading so the socket is drained.
      ws.listen(
        (dynamic data) => pi._onMessage(ws, data),
        onError: (Object _) {},
        onDone: () {},
      );
      ws.add(
        jsonEncode({
          'type': 'hello',
          'protocol': 1,
          'transport': 'wifi',
          'device': 'wmr-pi',
          'version': '0.2.4',
          'hostname': 'pi',
          'bridge_id': bridgeId,
          'authRequired': false,
          'streams': ['raw', 'decoded', 'batched'],
          'recordSize': 56,
          'batchMax': 9,
          'fragmentCapacity': 244,
        }),
      );
    });
    return pi;
  }

  void _onMessage(WebSocket ws, dynamic data) {
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map || decoded['type'] != 'ping' || !answerPings) return;
    final pong = jsonEncode({
      'type': 'pong',
      'id': decoded['id'],
      't': decoded['t'],
      'serverTimeUs': 0,
    });
    if (pongDelay <= Duration.zero) {
      _sendPong(ws, pong);
      return;
    }
    Timer(pongDelay, () {
      if (_stopped || ws.readyState != WebSocket.open) return;
      _sendPong(ws, pong);
    });
  }

  void _sendPong(WebSocket ws, String pong) {
    ws.add(pong);
    pongAt.add(DateTime.now());
  }

  Future<void> stop() {
    _stopped = true;
    return _server.close(force: true);
  }
}

void main() {
  late _FakeTcp tcp;
  late FakeTransport ble;

  FakeTransport newBle({Uint8List? ff16}) {
    final transport = FakeTransport(
      devices: const [
        FakeDevice(
          id: _bleDeviceId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
      ],
    );
    transport.onRead = (deviceId, characteristicUuid) {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        return ff16 ?? _versionString();
      }
      throw StateError('unexpected read $characteristicUuid');
    };
    return transport;
  }

  BleScanResult tcpScanResult() => BleScanResult(
    deviceId: _tcpDeviceId,
    name: 'WMR Bridge (127.0.0.1)',
    rssi: null,
    serviceUuids: const [wmrBridgeServiceUuid],
  );

  /// Boots the dark-port route the upgrade-cadence tests share: the TCP
  /// leg answers and carries, then the port goes dark and the leg drops, so
  /// the route fails over to BLE with the FF16 endpoint naming
  /// `127.0.0.1:8765` and the upgrade probe dialling a port that no longer
  /// answers. The probe budget is the production default (3 s): the
  /// upgrade dial's own cap is what keeps every failed pass short, not a
  /// budget shrunken here.
  Future<(_DarkPortTcp, CompositeBleTransport)> bootDarkRoute({
    bool hang = true,
    Duration tcpProbeBudget = const Duration(seconds: 3),
    Duration upgradeInterval = const Duration(seconds: 2),
    Duration upgradeRetryDelay = const Duration(milliseconds: 100),
    Duration upgradeRetryWindow = const Duration(seconds: 30),
  }) async {
    await tcp.dispose();
    final dark = _DarkPortTcp(hang: hang)
      ..registerEndpoint(
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: 8765,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      )
      ..scanResults.add(tcpScanResult());
    tcp = dark;
    ble.dispose();
    ble = newBle(ff16: _endpointDocument());
    final transport = CompositeBleTransport(
      tcp: dark,
      ble: ble,
      tcpProbeBudget: tcpProbeBudget,
      upgradeInterval: upgradeInterval,
      upgradeRetryDelay: upgradeRetryDelay,
      upgradeRetryWindow: upgradeRetryWindow,
    );
    addTearDown(transport.dispose);
    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
    // Let the watched leg's state stream attach before the leg drops.
    await _settle();
    dark.goDark();
    dark.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'the stalled TCP leg did not fail over to BLE',
    );
    return (dark, transport);
  }

  setUp(() {
    tcp = _FakeTcp()
      ..registerEndpoint(
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: 8765,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      )
      ..scanResults.add(tcpScanResult());
    ble = newBle(ff16: _endpointDocument());
  });

  tearDown(() async {
    await tcp.dispose();
    await ble.dispose();
  });

  test('connects over TCP first and keeps subscriptions on TCP', () async {
    final transport = CompositeBleTransport(tcp: tcp, ble: ble);
    addTearDown(transport.dispose);

    final scans = await transport.scan().toList();
    expect(
      scans.map((result) => result.deviceId),
      containsAll([_tcpDeviceId, _bleDeviceId]),
    );

    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
    expect(tcp.connectCalls, [_tcpDeviceId]);
    expect(
      await ble.connectionState(_bleDeviceId).first,
      BleConnectionState.disconnected,
    );
    expect(
      await transport.connectionState(_tcpDeviceId).first,
      BleConnectionState.connected,
    );

    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);

    expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1, 2, 3]), isTrue);
    await _settle();
    expect(received.single.value, [1, 2, 3]);
  });

  test(
    'falls back to BLE and upgrades to TCP without closing the stream',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      ble = newBle(ff16: _endpointDocument());
      tcp.scanResults
        ..clear()
        ..add(tcpScanResult());
      tcp.hellos.clear();

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      final states = <BleConnectionState>[];
      final stateSub = transport
          .connectionState(_tcpDeviceId)
          .listen(states.add);
      addTearDown(stateSub.cancel);

      await transport.connect(_tcpDeviceId);
      expect(
        await ble.connectionState(_bleDeviceId).first,
        BleConnectionState.connected,
      );
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
      expect(transport.bridgeIdFor(_tcpDeviceId), _bridgeId);

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add);
      addTearDown(sub.cancel);

      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [7]), isTrue);
      await _settle();
      expect(received.single.value, [7]);

      states.clear();
      tcp.failConnect = false;
      // The configured id was only a fallback for the initial attempt; this
      // test follows the FF16 endpoint document to `_lanDeviceId`.
      tcp.endpoints.remove(_tcpDeviceId);
      await _waitFor(
        () => tcp.connectCalls.contains(_lanDeviceId),
        reason: 'the FF16 endpoint was not probed',
      );
      await _waitFor(
        () => ble.cccLog.contains('off $wmrBridgeBatchedCharUuid'),
        reason: 'the BLE CCC was not turned off after the upgrade',
      );

      expect(tcp.emit(_lanDeviceId, wmrBridgeBatchedCharUuid, [8]), isTrue);
      await _settle();
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
      expect(received.last.value, [8]);
      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [9]), isFalse);
      expect(states, isNot(contains(BleConnectionState.disconnected)));

      // Both transports now name the same bridge_id, so a later scan keeps one
      // entry for it.
      final deduped = await transport.scan().toList();
      expect(deduped, hasLength(1));
    },
  );

  test(
    'switching to Wi-Fi turns the stream CCCD off and keeps the BLE link',
    () async {
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
      );
      addTearDown(transport.dispose);

      await transport.connect(_bleDeviceId);
      expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _bleDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeStreamCharUuid,
          )
          .listen(received.add);
      addTearDown(sub.cancel);
      expect(ble.cccLog, contains('on $wmrBridgeStreamCharUuid'));

      await transport.suspendBleStreams(_bleDeviceId);

      expect(ble.cccLog, contains('off $wmrBridgeStreamCharUuid'));
      expect(
        await ble.connectionState(_bleDeviceId).first,
        BleConnectionState.connected,
        reason: 'the switch must not drop the bonded BLE link',
      );
      expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);
    },
  );

  test('a BLE-only connect learns FF16 and upgrades to TCP', () async {
    ble.dispose();
    ble = newBle(ff16: _endpointDocument());

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
    );
    addTearDown(transport.dispose);

    // The Bluetooth tab knows only the BLE device id; the LAN host is in the
    // FF16 document, not in the transport's endpoints.
    expect(tcp.endpointFor(_bleDeviceId), isNull);
    await transport.connect(_bleDeviceId);

    expect(transport.bridgeIdFor(_bleDeviceId), _bridgeId);
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'the FF16 LAN host was not dialled',
    );
    expect(tcp.connectCalls, contains(_lanDeviceId));
    expect(
      await transport.connectionState(_bleDeviceId).first,
      BleConnectionState.connected,
    );
  });

  test(
    'reads the FF13 token before dialling an authRequired FF16 host',
    () async {
      ble.dispose();
      ble = newBle(ff16: _endpointDocument(authRequired: true));
      ble.onRead = (deviceId, characteristicUuid) {
        final normalized = characteristicUuid.toLowerCase();
        if (normalized == wmrBridgeVersionCharUuid) {
          return _endpointDocument(authRequired: true);
        }
        if (normalized == wmrBridgeConfigCharUuid) {
          return _sessionToken();
        }
        throw StateError('unexpected read $characteristicUuid');
      };

      String? learnedToken;
      String? learnedBridgeId;
      List<String>? learnedHosts;
      int? learnedPort;
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
        onTokenLearned: (bridgeId, hosts, port, token) {
          learnedBridgeId = bridgeId;
          learnedHosts = hosts;
          learnedPort = port;
          learnedToken = token;
        },
      );
      addTearDown(transport.dispose);

      await transport.connect(_bleDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
        reason: 'the authenticated FF16 LAN host was not dialled',
      );

      expect(tcp.endpoints[_lanDeviceId]?.token, 'secret');
      expect(learnedBridgeId, _bridgeId);
      expect(learnedHosts, ['127.0.0.1']);
      expect(learnedPort, 8765);
      expect(learnedToken, 'secret');
    },
  );

  test(
    'waits for a BLE scan hit that lands after the TCP dial fails',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      final gated = _GatedScanBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
        results: [
          BleScanResult(
            deviceId: _bleDeviceId,
            name: 'WMR Bridge',
            rssi: -40,
            serviceUuids: const [wmrBridgeServiceUuid],
          ),
        ],
      );
      gated.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _versionString();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      ble = gated;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
        bleScanWait: const Duration(seconds: 2),
      );
      addTearDown(transport.dispose);
      var scanDone = false;
      final sub = transport.scan().listen(
        (_) {},
        onDone: () => scanDone = true,
      );
      addTearDown(sub.cancel);
      await _settle();

      final connecting = transport.connect(_tcpDeviceId);
      await _settle();

      // The TCP refusal has been seen and connect is parked on the scan wait,
      // with no BLE hit yet.
      expect(tcp.connectCalls, [_tcpDeviceId]);
      expect(transport.activeLegFor(_tcpDeviceId), isNull);
      expect(scanDone, isFalse);

      gated.finishScan();
      await connecting;

      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
      expect(
        await ble.connectionState(_bleDeviceId).first,
        BleConnectionState.connected,
      );
    },
  );

  test(
    'reports the TCP error when the scan finds no BLE bridge in time',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      final gated = _GatedScanBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
        results: [
          BleScanResult(
            deviceId: _bleDeviceId,
            name: 'WMR Bridge',
            rssi: -40,
            serviceUuids: const [wmrBridgeServiceUuid],
          ),
        ],
      );
      gated.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _versionString();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      ble = gated;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
        bleScanWait: const Duration(milliseconds: 30),
      );
      addTearDown(transport.dispose);
      final sub = transport.scan().listen((_) {});
      addTearDown(sub.cancel);
      await _settle();

      await expectLater(
        transport.connect(_tcpDeviceId),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'tcp down',
          ),
        ),
      );

      expect(transport.activeLegFor(_tcpDeviceId), isNull);
      expect(
        await ble.connectionState(_bleDeviceId).first,
        BleConnectionState.disconnected,
      );
    },
  );

  test('a TCP disconnect moves an open stream to BLE', () async {
    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
      upgradeProbeBudget: Duration.zero,
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);

    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);

    expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1]), isTrue);
    await _settle();
    expect(received.single.value, [1]);

    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);
    await _settle();
    states.clear();

    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => ble.isSubscribed(_bleDeviceId, wmrBridgeBatchedCharUuid),
      reason: 'the stream was not reattached to BLE',
    );

    expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [2]), isTrue);
    await _settle();
    expect(received.last.value, [2]);
    expect(states, isNot(contains(BleConnectionState.disconnected)));
  });

  test('a synthetic stall records the recovery timeline in order', () async {
    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
      upgradeProbeBudget: Duration.zero,
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);

    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen((_) {});
    addTearDown(sub.cancel);

    expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1]), isTrue);
    await _settle();
    final before = transport.linkTimelineFor(_tcpDeviceId)!;
    expect(before['last_tcp_record_us'], isNotNull);
    expect(before['stall_detected_us'], isNull);

    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'the stalled TCP leg did not fail over to BLE',
    );
    // Keep the failover's end and the first BLE record apart, so the gap
    // between them is real rather than a same-tick coincidence.
    await _settle();
    expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [2]), isTrue);
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['first_ble_record_us'] !=
          null,
      reason: 'the first BLE record was not marked on the timeline',
    );

    final marks = transport.linkTimelineFor(_tcpDeviceId)!;
    // One entry per recovery step, under the keys the bundle carries.
    expect(marks.keys, unorderedEquals(_timelineKeys));
    final lastTcp = marks['last_tcp_record_us']! as int;
    final stall = marks['stall_detected_us']! as int;
    final begin = marks['failover_begin_us']! as int;
    final end = marks['failover_end_us']! as int;
    final firstBle = marks['first_ble_record_us']! as int;
    // No upgrade ran, so no dial or TCP-record mark may exist.
    expect(marks['upgrade_dial_start_us'], isNull);
    expect(marks['upgrade_dial_end_us'], isNull);
    expect(marks['first_tcp_record_us'], isNull);
    // Mark order: the stall follows the last TCP record, the failover
    // follows the stall, and the first BLE record follows the failover.
    expect(stall, greaterThan(lastTcp));
    expect(begin, greaterThanOrEqualTo(stall));
    expect(end, greaterThanOrEqualTo(begin));
    expect(firstBle, greaterThan(end));
    // The recorded episode spans a non-zero gap end to end.
    expect(firstBle - lastTcp, greaterThan(0));
  });

  for (final timeout in [false, true]) {
    test('a BLE-drop recovery dial that ${timeout ? 'times out' : 'throws'} '
        'counts once and records its outcome', () async {
      await tcp.dispose();
      tcp = _FakeTcp()
        ..registerEndpoint(
          WmrWsEndpoint(host: '127.0.0.1', port: 8765, deviceId: _tcpDeviceId),
        )
        ..scanResults.add(tcpScanResult());
      tcp.hellos[_tcpDeviceId] = WmrWsHello(
        protocol: 1,
        transport: 'tcp',
        device: _tcpDeviceId,
        version: '0.2.4',
        hostname: 'wmrpi',
        authRequired: false,
        streams: const {'raw', 'decoded', 'batched'},
        recordSize: 56,
        batchMax: 9,
        fragmentCapacity: 46,
      );
      ble.dispose();
      ble = newBle();
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
        upgradeProbeBudget: Duration.zero,
        tcpProbeBudget: const Duration(milliseconds: 100),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen((_) {});
      addTearDown(sub.cancel);
      expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1]), isTrue);
      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'the stalled TCP leg did not fail over to BLE',
      );
      await _settle();
      final before =
          transport.linkTimelineFor(_tcpDeviceId)!['upgrade_dial_attempts']!
              as int;
      final dialsBefore = tcp.connectCalls.length;

      if (timeout) {
        tcp.hangConnect = true;
      } else {
        tcp.failConnect = true;
      }
      unawaited(ble.disconnect(_bleDeviceId));
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == null,
        reason: 'the failed recovery never reported the loss',
      );
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(marks['upgrade_dial_attempts'], before + 1);
      expect(marks['upgrade_outcome'], 'connect_threw');
      expect(marks['upgrade_candidate_count'], 1);
      // One dial, and nothing re-arms a second after the route is lost.
      final dials = tcp.connectCalls.length - dialsBefore;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(tcp.connectCalls.length - dialsBefore, dials);
      expect(dials, 1);
    });
  }

  test('a BLE drop recovered over TCP records the dial, and a later failover clears it', () async {
    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
      upgradeProbeBudget: Duration.zero,
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);

    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen((_) {});
    addTearDown(sub.cancel);

    // Fail over to BLE first, so a BLE drop has a route to recover.
    expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1]), isTrue);
    await _settle();
    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'the stalled TCP leg did not fail over to BLE',
    );
    final failoverEnd =
        transport.linkTimelineFor(_tcpDeviceId)!['failover_end_us']! as int;

    // The BLE link drops: the recovery dials back to TCP and marks it.
    unawaited(ble.disconnect(_bleDeviceId));
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'the dropped BLE link was not recovered over TCP',
    );
    await _settle();
    expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [2]), isTrue);
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['first_tcp_record_us'] !=
          null,
      reason: 'the first TCP record after the recovery was not marked',
    );

    final recovered = transport.linkTimelineFor(_tcpDeviceId)!;
    final dialStart = recovered['upgrade_dial_start_us']! as int;
    final dialEnd = recovered['upgrade_dial_end_us']! as int;
    final firstTcp = recovered['first_tcp_record_us']! as int;
    // The recovery is a dial back to TCP, newer than the failover it
    // followed, and its first record follows the dial.
    expect(dialStart, greaterThan(failoverEnd));
    expect(dialEnd, greaterThan(dialStart));
    expect(firstTcp, greaterThan(dialEnd));

    // The next stall fails over again, and its begin clears the marks of
    // the episode it supersedes: the recovery's dial and first record.
    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'the recovered TCP leg did not fail over to BLE again',
    );
    final second = transport.linkTimelineFor(_tcpDeviceId)!;
    expect(second['upgrade_dial_start_us'], isNull);
    expect(second['upgrade_dial_end_us'], isNull);
    expect(second['first_tcp_record_us'], isNull);
    expect(second['failover_end_us']! as int, greaterThan(failoverEnd));
    // The second failover's stall is its own: it follows its own records.
    expect(
      second['stall_detected_us']! as int,
      greaterThan(second['last_tcp_record_us']! as int),
    );
  });

  test(
    'records every stall episode, the earlier ones preserved in order',
    () async {
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
        upgradeProbeBudget: Duration.zero,
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);

      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen((_) {});
      addTearDown(sub.cancel);

      // Episode one: the TCP leg stalls and the route fails over to BLE.
      expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1]), isTrue);
      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'the first stall did not fail over to BLE',
      );
      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [2]), isTrue);
      await _waitFor(
        () =>
            transport.linkTimelineFor(_tcpDeviceId)!['first_ble_record_us'] !=
            null,
        reason: "the first episode's first BLE record was not marked",
      );
      // What the top-level marks said while episode one was the most recent.
      final episodeOneLive = transport.linkTimelineFor(_tcpDeviceId)!;

      // The BLE link drops: the recovery dials back to TCP inside episode one,
      // and a record lands there.
      unawaited(ble.disconnect(_bleDeviceId));
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the dropped BLE link was not recovered over TCP',
      );
      expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [3]), isTrue);
      await _settle();

      // Episode two: its stall supersedes episode one, which moves into the
      // history with its own marks.
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'the second stall did not fail over to BLE',
      );
      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [4]), isTrue);
      await _waitFor(
        () =>
            transport.linkTimelineFor(_tcpDeviceId)!['first_ble_record_us'] !=
            null,
        reason: "the second episode's first BLE record was not marked",
      );

      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      final episodes = marks['episodes']! as List<Object?>;
      expect(
        episodes,
        hasLength(1),
        reason: 'the first episode was not archived',
      );
      final episodeOne = episodes.single as Map<String, Object?>;
      // The first episode is preserved: its failover marks are the ones the
      // top level showed while it was the most recent episode.
      expect(
        episodeOne['last_tcp_record_us'],
        episodeOneLive['last_tcp_record_us'],
      );
      expect(
        episodeOne['stall_detected_us'],
        episodeOneLive['stall_detected_us'],
      );
      expect(
        episodeOne['failover_begin_us'],
        episodeOneLive['failover_begin_us'],
      );
      expect(episodeOne['failover_end_us'], episodeOneLive['failover_end_us']);
      expect(
        episodeOne['first_ble_record_us'],
        episodeOneLive['first_ble_record_us'],
      );

      final lastTcpOne = episodeOne['last_tcp_record_us']! as int;
      final stallOne = episodeOne['stall_detected_us']! as int;
      final beginOne = episodeOne['failover_begin_us']! as int;
      final endOne = episodeOne['failover_end_us']! as int;
      final firstBleOne = episodeOne['first_ble_record_us']! as int;
      final dialStartOne = episodeOne['upgrade_dial_start_us']! as int;
      final dialEndOne = episodeOne['upgrade_dial_end_us']! as int;
      final firstTcpOne = episodeOne['first_tcp_record_us']! as int;
      // The archived episode's marks are coherent end to end: its stall
      // follows the record that preceded it, and each step follows the last,
      // dial and first TCP record included.
      expect(stallOne, greaterThan(lastTcpOne));
      expect(beginOne, greaterThanOrEqualTo(stallOne));
      expect(endOne, greaterThanOrEqualTo(beginOne));
      expect(firstBleOne, greaterThan(endOne));
      expect(dialStartOne, greaterThan(firstBleOne));
      expect(dialEndOne, greaterThan(dialStartOne));
      expect(firstTcpOne, greaterThan(dialEndOne));

      // The second episode is the most recent one, and it follows the first.
      final stallTwo = marks['stall_detected_us']! as int;
      final beginTwo = marks['failover_begin_us']! as int;
      final endTwo = marks['failover_end_us']! as int;
      final firstBleTwo = marks['first_ble_record_us']! as int;
      expect(stallTwo, greaterThan(firstTcpOne));
      expect(stallTwo, greaterThan(marks['last_tcp_record_us']! as int));
      expect(beginTwo, greaterThanOrEqualTo(stallTwo));
      expect(endTwo, greaterThanOrEqualTo(beginTwo));
      expect(firstBleTwo, greaterThan(endTwo));
      expect(endOne, lessThan(beginTwo));

      // Episode three archives the second: the history keeps the last
      // episodes in order, the first still preserved.
      unawaited(ble.disconnect(_bleDeviceId));
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the second dropped BLE link was not recovered over TCP',
      );
      expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [5]), isTrue);
      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'the third stall did not fail over to BLE',
      );

      final history = transport.linkTimelineFor(_tcpDeviceId)!;
      final list = history['episodes']! as List<Object?>;
      expect(list, hasLength(2));
      final episodeTwo = list[1] as Map<String, Object?>;
      expect((list[0] as Map)['failover_end_us'], endOne);
      expect(episodeTwo['stall_detected_us'], stallTwo);
      expect(episodeTwo['failover_end_us'], endTwo);
      expect(episodeTwo['first_ble_record_us'], firstBleTwo);
      expect(episodeTwo['failover_begin_us']! as int, greaterThan(endOne));
    },
  );

  test('a TCP loss during the upgrade activation archives the standing episode '
      'once', () async {
    // The recovery from a BLE drop dials back to TCP, and the BLE-notify
    // disable it runs while still holding the route is where the TCP leg
    // reports lost: the loss is remembered, not freshly detected.
    ble.dispose();
    var dropped = false;
    final dropping =
        _DroppingBle(
            devices: const [
              FakeDevice(
                id: _bleDeviceId,
                name: 'WMR Bridge',
                services: fakeBridgeDeviceServices,
              ),
            ],
            onUnsubscribe: () {
              if (dropped) return;
              dropped = true;
              tcp.drop(_tcpDeviceId);
            },
          )
          ..onRead = (deviceId, characteristicUuid) {
            if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
              return _endpointDocument();
            }
            throw StateError('unexpected read $characteristicUuid');
          };
    ble = dropping;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
      upgradeProbeBudget: Duration.zero,
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);

    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen((_) {});
    addTearDown(sub.cancel);

    // Episode one: the TCP leg stalls and the route fails over to BLE.
    expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1]), isTrue);
    await _settle();
    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'the first stall did not fail over to BLE',
    );
    expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [2]), isTrue);
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['first_ble_record_us'] !=
          null,
      reason: "the first episode's first BLE record was not marked",
    );
    // What the top-level marks said while episode one was the most recent,
    // with nothing archived yet.
    final episodeOneLive = transport.linkTimelineFor(_tcpDeviceId)!;
    expect(episodeOneLive['episodes'], isEmpty);
    final failoverEndOne = episodeOneLive['failover_end_us']! as int;

    // The BLE link drops and the recovery dials back to TCP; the recovered
    // leg reports lost during that activation, so the loss is remembered,
    // and the failover it kicks archives the standing episode.
    unawaited(ble.disconnect(_bleDeviceId));
    await _waitFor(
      () =>
          transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble &&
          (transport.linkTimelineFor(_tcpDeviceId)!['failover_end_us']!
                  as int) >
              failoverEndOne,
      reason: 'the loss remembered during the activation was not retried',
    );

    // The new episode's first BLE record follows its own failover.
    expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [3]), isTrue);
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['first_ble_record_us'] !=
          episodeOneLive['first_ble_record_us'],
      reason: "the second episode's first BLE record was not marked",
    );

    final marks = transport.linkTimelineFor(_tcpDeviceId)!;
    final episodes = marks['episodes']! as List<Object?>;
    expect(
      episodes,
      hasLength(1),
      reason: 'the standing episode was not archived exactly once',
    );
    final episodeOne = episodes.single as Map<String, Object?>;
    // The archived episode is the one the top level described while it was
    // the most recent: its marks are the values it held then.
    expect(
      episodeOne['last_tcp_record_us'],
      episodeOneLive['last_tcp_record_us'],
    );
    expect(
      episodeOne['stall_detected_us'],
      episodeOneLive['stall_detected_us'],
    );
    expect(
      episodeOne['failover_begin_us'],
      episodeOneLive['failover_begin_us'],
    );
    expect(episodeOne['failover_end_us'], episodeOneLive['failover_end_us']);
    expect(
      episodeOne['first_ble_record_us'],
      episodeOneLive['first_ble_record_us'],
    );

    // The recovery dial landed inside the standing episode, and the loss
    // cut it before any record reached the recovered leg.
    final firstBleOne = episodeOne['first_ble_record_us']! as int;
    final dialStartOne = episodeOne['upgrade_dial_start_us']! as int;
    final dialEndOne = episodeOne['upgrade_dial_end_us']! as int;
    expect(dialStartOne, greaterThan(firstBleOne));
    expect(dialEndOne, greaterThan(dialStartOne));
    expect(episodeOne['first_tcp_record_us'], isNull);

    // The new episode opened from the remembered loss: no fresh stall of
    // its own — the standing one stays — and its failover follows the
    // recovery dial it superseded, with the dial marks gone.
    expect(marks['stall_detected_us'], episodeOneLive['stall_detected_us']);
    final beginTwo = marks['failover_begin_us']! as int;
    final endTwo = marks['failover_end_us']! as int;
    expect(beginTwo, greaterThan(dialEndOne));
    expect(endTwo, greaterThanOrEqualTo(beginTwo));
    expect(marks['first_ble_record_us']! as int, greaterThan(endTwo));
    expect(marks['upgrade_dial_start_us'], isNull);
    expect(marks['upgrade_dial_end_us'], isNull);
    expect(marks['first_tcp_record_us'], isNull);
    // No TCP record ever landed past episode one's, so the top-level mark
    // still names the record the archived episode froze.
    expect(marks['last_tcp_record_us'], episodeOneLive['last_tcp_record_us']);

    // The recovered leg the loss named was closed on the way back to BLE.
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
    expect(tcp.tcpDisconnects, contains(_tcpDeviceId));
  });

  test('a silent TCP socket fails over to BLE within 2500 ms', () async {
    final pi = await _LoopbackPi.start(bridgeId: _bridgeId);
    pi.answerPings = false;
    final tcpLink = WmrWsTransport(
      endpoints: [
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: pi.port,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      ],
    );
    addTearDown(pi.stop);

    final transport = CompositeBleTransport(
      tcp: tcpLink,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);

    final stopwatch = Stopwatch()..start();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);

    await _waitFor(
      () =>
          transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble &&
          ble.cccLog.contains('on $wmrBridgeBatchedCharUuid'),
      timeout: const Duration(seconds: 3),
      reason: 'the silent TCP socket did not fail over to BLE',
    );
    stopwatch.stop();

    expect(
      stopwatch.elapsed,
      lessThan(const Duration(milliseconds: 2500)),
      reason: 'stall detection plus failover must stay inside 2500 ms',
    );
    expect(states, isNot(contains(BleConnectionState.disconnected)));
    expect(tcpLink.helloFor(_tcpDeviceId), isNull);

    expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [3]), isTrue);
    await _settle();
    expect(received.last.value, [3]);
  });

  test(
    'a peer that answers and then goes silent stalls within 1500 ms',
    () async {
      final pi = await _LoopbackPi.start(bridgeId: _bridgeId);
      addTearDown(pi.stop);
      final tcpLink = WmrWsTransport(
        endpoints: [
          WmrWsEndpoint(
            host: '127.0.0.1',
            port: pi.port,
            deviceId: _tcpDeviceId,
            bridgeId: _bridgeId,
          ),
        ],
      );
      final transport = CompositeBleTransport(
        tcp: tcpLink,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

      // The link is healthy first: at least two probes were answered.
      await _waitFor(
        () => pi.pongAt.length >= 2,
        reason: 'the liveness probes were not answered before the silence',
      );

      // Silence the peer right after one more pong, so the stall's budget
      // is measured from the last answer the link gave.
      final answered = pi.pongAt.length;
      await _waitFor(
        () => pi.pongAt.length > answered,
        timeout: const Duration(seconds: 2),
        reason: 'no further probe was answered',
      );
      pi.answerPings = false;
      final silentAtUs = transport.clock.nowUs;
      await _waitFor(
        () =>
            transport.linkTimelineFor(_tcpDeviceId)!['stall_detected_us'] !=
            null,
        timeout: const Duration(seconds: 3),
        reason: 'the silent peer was not detected as a stall',
      );

      // The detector defaults are a 500 ms interval and a 1000 ms deadline,
      // so the stall lands within 1500 ms of the last pong the peer sent;
      // the slack left above that budget is the event loop's timer
      // lateness.
      final stallUs =
          transport.linkTimelineFor(_tcpDeviceId)!['stall_detected_us']! as int;
      expect(
        stallUs - silentAtUs,
        lessThanOrEqualTo(1550000),
        reason: 'the stall outlived the 1500 ms liveness budget',
      );

      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'the silent peer did not fail over to BLE',
      );

      // The stall episode is recorded: its marks name the detection and the
      // failover it began. It is still the most recent episode, so the
      // history behind it is empty.
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      final stall = marks['stall_detected_us']! as int;
      final begin = marks['failover_begin_us']! as int;
      final end = marks['failover_end_us']! as int;
      expect(begin, greaterThanOrEqualTo(stall));
      expect(end, greaterThanOrEqualTo(begin));
      expect(marks['episodes']! as List, isEmpty);
    },
  );

  test('a pong just inside the deadline never fails over', () async {
    final pi = await _LoopbackPi.start(bridgeId: _bridgeId);
    pi.pongDelay = const Duration(milliseconds: 900);
    addTearDown(pi.stop);
    final tcpLink = WmrWsTransport(
      endpoints: [
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: pi.port,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      ],
    );
    final transport = CompositeBleTransport(
      tcp: tcpLink,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

    // Every probe's answer lands 900 ms later, 100 ms inside the detector's
    // 1000 ms deadline: a slow but live link. Three answers prove the
    // detector re-arms and re-survives each deadline.
    await _waitFor(
      () => pi.pongAt.length >= 3,
      timeout: const Duration(seconds: 8),
      reason: 'the delayed pongs were not answered',
    );

    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
    expect(states, isNot(contains(BleConnectionState.disconnected)));
    final marks = transport.linkTimelineFor(_tcpDeviceId)!;
    expect(
      marks['stall_detected_us'],
      isNull,
      reason: 'a live link was recorded as a stall',
    );
    expect(
      marks['episodes'],
      isEmpty,
      reason: 'a live link recorded a stall episode',
    );
  });

  test(
    'a TCP loss delivered while a switch holds the route is retried',
    () async {
      tcp.dropOnWatch = true;
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
        upgradeProbeBudget: Duration.zero,
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);

      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'the loss that landed during activation was dropped',
      );
      expect(tcp.tcpDisconnects, contains(_tcpDeviceId));

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add);
      addTearDown(sub.cancel);
      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [4]), isTrue);
      await _settle();
      expect(received.single.value, [4]);
    },
  );

  test(
    'a loss while the FF16 upgrade activates TCP falls back to BLE',
    () async {
      ble.dispose();
      ble = newBle();
      // The first FF16 read names the LAN host; the fallback's re-read only
      // returns a version string, so no second upgrade probe follows and the
      // route stays on BLE.
      final document = _endpointDocument();
      var ff16Reads = 0;
      ble.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return ff16Reads++ == 0 ? document : _versionString();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      // The dial succeeds, but the leg reports `disconnected` on subscribe,
      // before the switch names TCP active: only the upgrade's own release can
      // retry that loss.
      tcp.dropOnWatch = true;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_bleDeviceId);
      expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

      await _waitFor(
        () =>
            tcp.tcpDisconnects.contains(_lanDeviceId) &&
            transport.activeLegFor(_bleDeviceId) == CompositeLeg.ble,
        reason: 'the loss during the upgrade activation was not retried',
      );
      expect(tcp.connectCalls, contains(_lanDeviceId));

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _bleDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add);
      addTearDown(sub.cancel);

      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [5]), isTrue);
      await _settle();
      expect(received.single.value, [5]);
    },
  );

  test(
    're-promotes a configured TCP endpoint when FF16 is a version string',
    () async {
      await tcp.dispose();
      tcp = _FakeTcp()
        ..registerEndpoint(
          WmrWsEndpoint(host: '127.0.0.1', port: 8765, deviceId: _tcpDeviceId),
        )
        ..scanResults.add(tcpScanResult())
        ..failConnect = true;
      ble.dispose();
      ble = newBle();
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.bridgeIdFor(_tcpDeviceId), isNull);

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add);
      addTearDown(sub.cancel);

      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [7]), isTrue);
      await _settle();
      expect(received.single.value, [7]);

      tcp.failConnect = false;
      await _waitFor(
        () => ble.cccLog.contains('off $wmrBridgeBatchedCharUuid'),
        reason: 'the configured TCP endpoint was not retried',
      );
      expect(transport.bridgeIdFor(_tcpDeviceId), _bridgeId);

      expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [8]), isTrue);
      await _settle();
      expect(received.last.value, [8]);
      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [9]), isFalse);
    },
  );

  test(
    'a reconnect waits for an in-flight failover instead of returning early',
    () async {
      ble.dispose();
      final gated =
          _GatedConnectBle(
              devices: const [
                FakeDevice(
                  id: _bleDeviceId,
                  name: 'WMR Bridge',
                  services: fakeBridgeDeviceServices,
                ),
              ],
            )
            ..onRead = (deviceId, characteristicUuid) {
              if (characteristicUuid.toLowerCase() ==
                  wmrBridgeVersionCharUuid) {
                return _endpointDocument();
              }
              throw StateError('unexpected read $characteristicUuid');
            };
      ble = gated;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
        upgradeProbeBudget: Duration.zero,
      );
      addTearDown(transport.dispose);
      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);

      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen((_) {});
      addTearDown(sub.cancel);

      // The TCP leg drops, so the composite starts moving the session to BLE
      // and parks in its switching window until the gated connect returns.
      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => gated.connectCalls.isNotEmpty,
        reason: 'the failover never reached the BLE dial',
      );

      var reconnected = false;
      final reconnect = transport
          .connect(_tcpDeviceId)
          .whenComplete(() => reconnected = true);
      await _settle(50);
      expect(
        reconnected,
        isFalse,
        reason: 'connect returned while the failover was still in flight',
      );

      gated.gate.complete();
      await reconnect.timeout(const Duration(seconds: 2));
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
    },
  );

  test(
    'disconnect does not wait for a deferred connection-state cancel',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      final stuck =
          _StuckCancelBle(
              devices: const [
                FakeDevice(
                  id: _bleDeviceId,
                  name: 'WMR Bridge',
                  services: fakeBridgeDeviceServices,
                ),
              ],
            )
            ..onRead = (deviceId, characteristicUuid) {
              if (characteristicUuid.toLowerCase() ==
                  wmrBridgeVersionCharUuid) {
                return _versionString();
              }
              throw StateError('unexpected read $characteristicUuid');
            };
      ble = stuck;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
      );
      addTearDown(() async {
        stuck.cancelGate.complete();
        await transport.dispose();
      });
      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

      await transport
          .disconnect(_tcpDeviceId)
          .timeout(const Duration(seconds: 1));
      expect(transport.activeLegFor(_tcpDeviceId), isNull);
      expect(
        await transport.connectionState(_tcpDeviceId).first,
        BleConnectionState.disconnected,
      );
    },
  );

  test('does not move a TCP session to a different BLE bridge', () async {
    ble.dispose();
    ble = FakeTransport(
      devices: const [
        FakeDevice(
          id: _bleDeviceId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
        FakeDevice(
          id: 'ble-2',
          name: 'Other Bridge',
          services: fakeBridgeDeviceServices,
        ),
      ],
    );
    ble.onRead = (deviceId, characteristicUuid) {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        return deviceId == _bleDeviceId
            ? _versionString()
            : _endpointDocument(bridgeId: 'pi-2');
      }
      throw StateError('unexpected read $characteristicUuid');
    };

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.bridgeIdFor(_tcpDeviceId), _bridgeId);

    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);
    await _settle();
    states.clear();

    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => states.contains(BleConnectionState.disconnected),
      reason: 'the composite switched to a bridge it could not identify',
    );
    expect(
      await ble.connectionState('ble-2').first,
      BleConnectionState.disconnected,
    );
    expect(
      await ble.connectionState(_bleDeviceId).first,
      BleConnectionState.disconnected,
    );
  });

  test('dialing BLE at once when no LAN interface is up', () async {
    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      lanAvailable: () async => false,
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);

    expect(tcp.connectCalls, isEmpty);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
    expect(
      await ble.connectionState(_bleDeviceId).first,
      BleConnectionState.connected,
    );
  });

  test('caps a TCP dial that never answers and falls back to BLE', () async {
    tcp.hangConnect = true;
    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      tcpProbeBudget: const Duration(milliseconds: 100),
      upgradeInterval: Duration.zero,
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    final elapsed = Stopwatch()..start();
    await transport.connect(_tcpDeviceId);
    elapsed.stop();

    expect(tcp.connectCalls, [_tcpDeviceId]);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
  });

  test('keeps the TCP budget at three seconds or less', () {
    final transport = CompositeBleTransport(tcp: tcp, ble: ble);
    addTearDown(transport.dispose);

    expect(
      transport.tcpProbeBudget,
      lessThanOrEqualTo(const Duration(seconds: 3)),
    );
  });

  test('keeps the upgrade retry cadence inside its bounds', () {
    final transport = CompositeBleTransport(tcp: tcp, ble: ble);
    addTearDown(transport.dispose);

    expect(
      transport.upgradeRetryDelay,
      lessThanOrEqualTo(const Duration(milliseconds: 100)),
      reason: 'a failed attempt must retry within 100 ms',
    );
    expect(
      transport.upgradeRetryWindow,
      lessThanOrEqualTo(const Duration(seconds: 30)),
      reason: 'the fast cadence must stop within 30 s of a failover',
    );
    expect(
      transport.upgradeProbeBudget,
      lessThanOrEqualTo(const Duration(milliseconds: 300)),
      reason: 'a failed attempt must end within 300 ms',
    );
  });

  test('a failed upgrade attempt ends fast, closes its socket, and retries '
      'within 100 ms', () async {
    final (dark, transport) = await bootDarkRoute();

    // The upgrade failures must stay contained: the route keeps reporting
    // connected on BLE while the fast cadence runs.
    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);

    // The FF16 kick dials at once and every failure re-arms the next
    // attempt at the fast cadence, so three whole passes land well
    // before the first periodic tick could dial a second time.
    await _waitFor(
      () => dark.dialAt.length - dark.darkFrom >= 6,
      timeout: const Duration(seconds: 6),
      reason: 'a failed attempt waited a whole tick for the next dial',
    );
    final passes = dark.closedAt.length ~/ 2;

    // Each failed attempt ends inside the 300 ms bound at the production
    // probe budget (3 s): the pass's last socket closed no later than the
    // upgrade dial's cap after the pass began, plus scheduler jitter.
    for (var pass = 0; pass < passes; pass++) {
      expect(
        Duration(
          microseconds:
              dark.closedAt[pass * 2 + 1] -
              dark.dialAt[dark.darkFrom + pass * 2],
        ),
        lessThan(const Duration(milliseconds: 400)),
        reason: 'a failed attempt outlived the 300 ms cap',
      );
    }

    // The next attempt starts within 100 ms of the last one's failure,
    // plus scheduler jitter.
    for (var pass = 0; pass + 1 < passes; pass++) {
      expect(
        Duration(
          microseconds:
              dark.dialAt[dark.darkFrom + (pass + 1) * 2] -
              dark.closedAt[pass * 2 + 1],
        ),
        lessThan(const Duration(milliseconds: 250)),
        reason: 'the next attempt started more than 100 ms later',
      );
    }

    // Every failed dial's socket was closed: no attempt leaked one. The
    // dial in flight when the window was sampled still has its slice to
    // run, so wait for its teardown before counting.
    final dials = dark.dialAt.length - dark.darkFrom;
    await _waitFor(() => dark.closedAt.length >= dials);
    expect(dark.closedAt.length, greaterThanOrEqualTo(dials));
    // The failures are contained: the route never reported a loss.
    expect(states, isNot(contains(BleConnectionState.disconnected)));
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    // Every finished pass is one counted attempt that ended as a failed
    // dial; the in-flight attempt may still be running and reads as null.
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['upgrade_outcome'] ==
          'connect_threw',
      reason: 'the failed attempt never recorded its outcome',
    );
    // A recorded outcome means no attempt is between its start and its dial,
    // so the count and the port's dials are read at one settled boundary.
    // Each attempt dials every candidate once.
    final marks = transport.linkTimelineFor(_tcpDeviceId)!;
    final candidates = marks['upgrade_candidate_count']! as int;
    expect(candidates, greaterThanOrEqualTo(1));
    expect(
      dark.dialAt.length - dark.darkFrom,
      (marks['upgrade_dial_attempts']! as int) * candidates,
      reason: 'the attempt count differs from the dials the port saw',
    );
  });

  test('the fast cadence stops when the post-failover window closes', () async {
    final (dark, transport) = await bootDarkRoute(
      upgradeInterval: const Duration(milliseconds: 1200),
      upgradeRetryDelay: const Duration(milliseconds: 100),
      upgradeRetryWindow: const Duration(milliseconds: 1000),
    );

    // The fast cadence chains attempts inside the window; once it closes
    // only the periodic tick dials, so six passes take a few ticks.
    await _waitFor(
      () => dark.dialAt.length - dark.darkFrom >= 12,
      timeout: const Duration(seconds: 8),
      reason: 'the upgrade attempts never resumed the tick cadence',
    );
    final starts = <int>[
      for (var i = dark.darkFrom; i < dark.dialAt.length; i += 2)
        dark.dialAt[i],
    ];
    expect(starts.length, greaterThanOrEqualTo(6));

    // Retries inside the window are fast: the kick and its re-arms chain
    // well under the tick.
    expect(
      Duration(microseconds: starts[1] - starts[0]),
      lessThan(const Duration(milliseconds: 550)),
      reason: 'the first retry waited for the tick instead of the re-arm',
    );
    expect(
      Duration(microseconds: starts[2] - starts[1]),
      lessThan(const Duration(milliseconds: 550)),
      reason: 'the second retry waited for the tick instead of the re-arm',
    );
    // Past the window only the tick dials: the last gap is tick-sized, so
    // the fast cadence never fired again after the window closed.
    expect(
      Duration(microseconds: starts.last - starts[starts.length - 2]),
      greaterThan(const Duration(milliseconds: 1000)),
      reason: 'a fast retry fired after the window closed',
    );
  });

  test('a non-positive upgrade interval disables the fast re-arm', () async {
    final (dark, transport) = await bootDarkRoute(
      upgradeInterval: Duration.zero,
    );

    // The FF16 kick dials once even with the automatic upgrade disabled,
    // and its failure must not chain the fast cadence: no dial may follow.
    await _waitFor(
      () => dark.dialAt.length - dark.darkFrom >= 2,
      reason: 'the FF16 kick did not dial',
    );
    final kicked = dark.dialAt.length - dark.darkFrom;
    // Several would-be re-arm deadlines pass inside the still-open
    // window; none of them may start a dial.
    await _settle(2000);
    expect(
      dark.dialAt.length - dark.darkFrom,
      kicked,
      reason: 'the fast cadence chained behind a disabled upgrade',
    );
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
  });

  test('a fast re-arm does not dial while a switch holds the route', () async {
    await tcp.dispose();
    final dark = _DarkPortTcp()
      ..registerEndpoint(
        WmrWsEndpoint(host: '127.0.0.1', port: 8765, bridgeId: _bridgeId),
      );
    tcp = dark;
    ble.dispose();
    ble = newBle(ff16: _endpointDocument());

    final transport = CompositeBleTransport(
      tcp: dark,
      ble: ble,
      tcpProbeBudget: const Duration(milliseconds: 1000),
      upgradeInterval: const Duration(seconds: 2),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    // One candidate only: the remembered id is the endpoint the FF16
    // document names again, so the probe and the recovery dial the same
    // address.
    await transport.connect(_lanDeviceId);
    expect(transport.activeLegFor(_lanDeviceId), CompositeLeg.tcp);

    // Let the watched leg's state stream attach before the leg drops.
    await _settle();
    dark.goDark();
    dark.drop(_lanDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_lanDeviceId) == CompositeLeg.ble,
      reason: 'the stalled TCP leg did not fail over to BLE',
    );

    // The kick's dial parks and its slice expires: the attempt failed and
    // the fast re-arm is now pending.
    await _waitFor(
      () => dark.closedAt.length >= 1,
      reason: 'the parked probe dial was never torn down',
    );

    // The BLE leg drops while the re-arm is pending: the recovery switch
    // takes the route and dials the same candidate for itself.
    unawaited(ble.disconnect(_bleDeviceId));
    await _waitFor(
      () => dark.dialAt.length - dark.darkFrom >= 2,
      reason: 'the BLE drop never started a recovery dial',
    );

    // The pending re-arm fires while the recovery still holds the route:
    // it must not open a second dial.
    await _settle(700);
    expect(
      dark.dialAt.length - dark.darkFrom,
      2,
      reason: 'a dial started while a switch held the route',
    );

    // The recovery's own slice expires: its socket is closed too, the
    // route is lost, and no later attempt dials again.
    await _waitFor(
      () => transport.activeLegFor(_lanDeviceId) == null,
      reason: 'the recovery never gave the route up',
    );
    await _settle(700);
    expect(dark.dialAt.length - dark.darkFrom, 2);
    expect(
      dark.closedAt.length,
      2,
      reason: 'a failed dial left its socket open',
    );
  });

  test(
    'a landing attempt ends the retries: one upgrade and no repeat dial',
    () async {
      final (dark, transport) = await bootDarkRoute();

      // A live channel gives the upgrade a stream to carry across the
      // switch, so the first TCP record after it lands is markable.
      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add);
      addTearDown(sub.cancel);

      // The first attempt fails against the dark port and re-arms.
      await _waitFor(
        () => dark.closedAt.length >= 2,
        reason: 'the first attempt never finished',
      );

      // The port answers again: the next fast attempt lands.
      dark.comeUp();
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the upgrade dial never landed',
      );

      // One upgrade: the landing attempt is the second and last dial, and
      // nothing dials again while TCP carries the route.
      await _settle(700);
      expect(
        dark.dialAt.length - dark.darkFrom,
        3,
        reason: 'the route dialled again after the upgrade landed',
      );
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(
        marks['upgrade_dial_attempts'],
        2,
        reason: 'the landing attempt was not the second dial',
      );
      final dialStart = marks['upgrade_dial_start_us']! as int;
      final dialEnd = marks['upgrade_dial_end_us']! as int;
      expect(
        Duration(microseconds: dialEnd - dialStart),
        lessThan(const Duration(milliseconds: 750)),
        reason: 'the landing attempt outlived the 750 ms bound',
      );

      expect(marks['upgrade_outcome'], 'landed');
      expect(marks['upgrade_candidate_count'], greaterThanOrEqualTo(1));

      // The next TCP record was stamped 300 ms before it reached the
      // listener. Its wall anchor must be the receipt instant, so it sits
      // 300 ms before the listener's wall clock, on the record's own stamp.
      const deliveryDelayUs = 300000;
      final beforeWallUs = DateTime.now().microsecondsSinceEpoch;
      expect(
        dark.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [
          9,
        ], receivedAtUs: dark.clock.nowUs - deliveryDelayUs),
        isTrue,
      );
      await _waitFor(
        () =>
            transport.linkTimelineFor(_tcpDeviceId)!['first_tcp_record_us'] !=
            null,
        reason: 'the first TCP record after the upgrade was not marked',
      );
      final afterWallUs = DateTime.now().microsecondsSinceEpoch;
      final landedMarks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(landedMarks['first_tcp_record_session'], _tcpDeviceId);
      final wallUs = landedMarks['first_tcp_record_wall_us']! as int;
      expect(
        wallUs,
        inInclusiveRange(
          beforeWallUs - deliveryDelayUs - 100000,
          afterWallUs - deliveryDelayUs,
        ),
      );
      await _settle(300);
      expect(
        dark.dialAt.length - dark.darkFrom,
        3,
        reason: 'a dial repeated the upgrade while TCP was active',
      );
    },
  );

  test(
    'dispose mid-dial closes the parked socket and stops the retries',
    () async {
      final (dark, transport) = await bootDarkRoute();

      // The kick pass parks its first candidate; the dispose lands while
      // that dial is in flight.
      await _waitFor(
        () => dark.dialAt.length - dark.darkFrom >= 1,
        reason: 'the upgrade probe never dialled',
      );
      await transport.dispose();

      // The in-flight pass still closes its parked sockets when their
      // slices expire, and no attempt dials after the dispose.
      await _waitFor(
        () => dark.closedAt.length == dark.dialAt.length - dark.darkFrom,
        reason: 'a disposed route left a parked socket open',
      );
      await _settle(700);
      expect(
        dark.dialAt.length - dark.darkFrom,
        2,
        reason: 'a dial started after the dispose',
      );
    },
  );

  test('an intentional disconnect mid-dial closes the parked socket and stops '
      'the retries', () async {
    final (dark, transport) = await bootDarkRoute();

    await _waitFor(
      () => dark.dialAt.length - dark.darkFrom >= 1,
      reason: 'the upgrade probe never dialled',
    );
    await transport.disconnect(_tcpDeviceId);

    await _waitFor(
      () => dark.closedAt.length == dark.dialAt.length - dark.darkFrom,
      reason: 'the disconnected route left a parked socket open',
    );
    await _settle(700);
    expect(
      dark.dialAt.length - dark.darkFrom,
      2,
      reason: 'a dial started after the disconnect',
    );
  });

  test(
    'an early dial before the port is up fails fast and keeps the cadence',
    () async {
      // The port is not up yet once dark: every dial is refused at once.
      final (dark, transport) = await bootDarkRoute(hang: false);

      // The early dial is the FF16 kick, not a tick, and the refusal does
      // not consume the next attempt's slot: the retry follows within
      // 100 ms, not a whole tick later.
      await _waitFor(
        () => dark.dialAt.length - dark.darkFrom >= 4,
        timeout: const Duration(seconds: 4),
        reason: 'the refused attempts were not retried at the fast cadence',
      );
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      final firstStart = marks['first_upgrade_dial_start_us']! as int;
      final failoverEnd = marks['failover_end_us']! as int;
      expect(
        Duration(microseconds: firstStart - failoverEnd),
        lessThan(const Duration(milliseconds: 500)),
        reason: 'the first attempt waited for a tick after the failover',
      );
      expect(
        Duration(
          microseconds:
              dark.dialAt[dark.darkFrom + 1] - dark.dialAt[dark.darkFrom],
        ),
        lessThan(const Duration(milliseconds: 300)),
        reason: 'the refused attempt outlived the 300 ms bound',
      );
      expect(
        Duration(
          microseconds:
              dark.dialAt[dark.darkFrom + 2] - dark.dialAt[dark.darkFrom + 1],
        ),
        lessThan(const Duration(milliseconds: 250)),
        reason: 'the early failure consumed the next attempt slot',
      );

      await _waitFor(
        () =>
            transport.linkTimelineFor(_tcpDeviceId)!['upgrade_outcome'] ==
            'connect_threw',
        reason: 'a refused dial never recorded a connect_threw outcome',
      );

      // The port comes up: the next fast attempt lands on it.
      dark.comeUp();
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the upgrade dial never landed once the port answered',
      );
      final landed = transport.linkTimelineFor(_tcpDeviceId)!;
      final dialStart = landed['upgrade_dial_start_us']! as int;
      final dialEnd = landed['upgrade_dial_end_us']! as int;
      expect(
        Duration(microseconds: dialEnd - dialStart),
        lessThan(const Duration(milliseconds: 750)),
        reason: 'the landing attempt outlived the 750 ms bound',
      );
      expect(
        landed['upgrade_dial_attempts'],
        greaterThanOrEqualTo(3),
        reason: 'the landing attempt never ran',
      );
    },
  );

  test('a dial failing until a chosen instant lands within 400 ms and re-arms '
      'within 100 ms', () async {
    // No LAN or Pi reachability callback is installed: the cadence must
    // depend only on the failed dial ending, not on a reachability probe.
    final (dark, transport) = await bootDarkRoute();

    // The kick's dial is in flight and failing. Choose the instant the
    // port comes back: inside the first dial's 300 ms probe, so that
    // dial still has to expire before the next attempt can land.
    await _waitFor(
      () => dark.dialAt.length - dark.darkFrom >= 1,
      reason: 'the upgrade probe never dialled',
    );
    final instant =
        dark.nowUs + const Duration(milliseconds: 200).inMicroseconds;
    dark.failUntilUs = instant;

    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      timeout: const Duration(seconds: 3),
      reason: 'a dial started after the port came back never landed',
    );

    final landedStart = dark.dialAt.last;
    expect(
      landedStart,
      greaterThanOrEqualTo(instant),
      reason: 'the landed dial started before the port came back',
    );
    // The in-flight dial burns its 300 ms probe, then the 100 ms re-arm
    // opens the attempt that lands: 400 ms after the port answered.
    expect(
      Duration(microseconds: landedStart - instant),
      lessThanOrEqualTo(const Duration(milliseconds: 400)),
      reason: 'the port was not reached within 400 ms of coming back',
    );
    expect(
      Duration(microseconds: landedStart - dark.closedAt.last),
      lessThan(const Duration(milliseconds: 250)),
      reason: 'the re-arm waited longer than the 100 ms cadence',
    );
  });

  test('an upgrade dial cuts a refusing candidate short and lands on the '
      'answering one', () async {
    const hostA = '192.168.1.50';
    const hostB = '127.0.0.1';
    final idA = '$hostA:$wmrWsDefaultPort';
    final idB = '$hostB:$wmrWsDefaultPort';
    await tcp.dispose();
    final refusing = _RefusingTcp({idA})..scanResults.add(tcpScanResult());
    tcp = refusing;
    ble.dispose();
    ble = newBle(ff16: _endpointDocument(hosts: const [hostA, hostB]));

    final transport = CompositeBleTransport(
      tcp: refusing,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'the upgrade dial never landed on the answering candidate',
    );
    await _settle(30);

    // The first candidate refused and the second answered: the refusing
    // candidate held only its bounded share, its abandoned socket was closed
    // before the answering one was dialled, and the answering one's socket
    // stayed open as the adopted session.
    expect(refusing.dialAt.map((dial) => dial.key), [idA, idB]);
    final aDialed = refusing.dialAt.first.value;
    final aClosed = refusing.closedAt[idA];
    expect(
      aClosed,
      isNotNull,
      reason: 'the refusing candidate kept its abandoned socket open',
    );
    final bDialed = refusing.dialAt.last.value;
    expect(
      aClosed!,
      lessThan(bDialed),
      reason:
          "the refusing candidate's socket was still open when the "
          'answering candidate was dialled',
    );
    expect(
      Duration(microseconds: aClosed - aDialed),
      lessThan(const Duration(milliseconds: 300)),
      reason: 'the refusing candidate held the attempt past its bounded share',
    );
    expect(
      refusing.closedAt.containsKey(idB),
      isFalse,
      reason: "the answering candidate's adopted socket was closed",
    );

    final marks = transport.linkTimelineFor(_bleDeviceId)!;
    final dialStart = marks['upgrade_dial_start_us']! as int;
    final dialEnd = marks['upgrade_dial_end_us']! as int;
    expect(
      Duration(microseconds: dialEnd - dialStart),
      lessThan(const Duration(milliseconds: 750)),
      reason: 'the upgrade dial outlived the 750 ms landing bound',
    );
  });

  test('a single answering candidate lands within the 750 ms bound', () async {
    ble.dispose();
    ble = newBle(ff16: _endpointDocument());

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'the upgrade dial never landed',
    );
    await _settle(30);

    expect(tcp.connectCalls, [
      _lanDeviceId,
    ], reason: 'the dial opened more than one TCP socket');
    final marks = transport.linkTimelineFor(_bleDeviceId)!;
    final dialStart = marks['upgrade_dial_start_us']! as int;
    final dialEnd = marks['upgrade_dial_end_us']! as int;
    expect(
      Duration(microseconds: dialEnd - dialStart),
      lessThan(const Duration(milliseconds: 750)),
      reason: 'a single answering candidate outlived the 750 ms landing bound',
    );
  });

  test('the last candidate keeps the whole budget, not the cap', () async {
    await tcp.dispose();
    final slow = _SlowDialTcp(const Duration(milliseconds: 400))
      ..registerEndpoint(
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: 8765,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      )
      ..scanResults.add(tcpScanResult());
    tcp = slow;
    ble.dispose();
    ble = newBle(ff16: _endpointDocument());

    // The handshake is slower than the share cap but well inside the
    // budget this test pins: at the default 300 ms upgrade budget a 400 ms
    // handshake is deliberately a failed attempt, so the exemption is
    // proven here against a budget that still admits it.
    final transport = CompositeBleTransport(
      tcp: slow,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
      upgradeProbeBudget: const Duration(seconds: 3),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'a slow but answering last candidate never landed',
    );
    await _settle(30);

    expect(slow.connectCalls, [
      _lanDeviceId,
    ], reason: 'the slow dial was abandoned and redialled');
    final marks = transport.linkTimelineFor(_bleDeviceId)!;
    final dialStart = marks['upgrade_dial_start_us']! as int;
    final dialEnd = marks['upgrade_dial_end_us']! as int;
    expect(
      Duration(microseconds: dialEnd - dialStart),
      greaterThan(const Duration(milliseconds: 250)),
      reason: 'the last candidate was cut to its 250 ms cap',
    );
    expect(
      Duration(microseconds: dialEnd - dialStart),
      lessThan(const Duration(milliseconds: 750)),
      reason: 'the slow dial outlived the 750 ms landing bound',
    );
  });

  test(
    'an abandoned dial cannot outlive the budget; the next tick dials fresh',
    () async {
      await tcp.dispose();
      final held = _HeldDialTcp()
        ..registerEndpoint(
          WmrWsEndpoint(host: '127.0.0.1', port: 8765, deviceId: _tcpDeviceId),
        )
        ..scanResults.add(tcpScanResult());
      held.hellos[_tcpDeviceId] = WmrWsHello(
        protocol: 1,
        transport: 'tcp',
        device: _tcpDeviceId,
        version: '0.2.4',
        hostname: 'wmrpi',
        authRequired: false,
        streams: const {'raw', 'decoded', 'batched'},
        recordSize: 56,
        batchMax: 9,
        fragmentCapacity: 46,
      );
      tcp = held;
      ble.dispose();
      ble = newBle();

      final transport = CompositeBleTransport(
        tcp: held,
        ble: ble,
        tcpProbeBudget: const Duration(milliseconds: 150),
        upgradeInterval: const Duration(milliseconds: 10),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      // The connect path's own dial is abandoned when its budget expires, and
      // must be torn down instead of left for a later dial to join.
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
      await _waitFor(
        () => held.disconnectCalls.isNotEmpty,
        reason: 'the abandoned dial outlived the budget',
      );
      expect(held.disconnectCalls, [_tcpDeviceId]);

      // The next upgrade tick dials fresh instead of joining the abandoned one.
      await _waitFor(
        () => held.freshDials >= 2,
        reason: 'the next tick joined the abandoned dial',
      );
      expect(held.joins, 0);
      final inFlight = held.freshDials;

      // While the tick's dial is in flight, no later tick opens a second one.
      await _settle(60);
      expect(
        held.freshDials,
        inFlight,
        reason: 'a tick dialled while another probe held the route',
      );

      // The tick's dial hits the same budget, is torn down, and the next tick
      // dials fresh again: no dial ever outlives the budget.
      await _waitFor(
        () => held.disconnectCalls.length >= 2,
        reason: 'the tick dial outlived its budget',
      );
      await _waitFor(
        () => held.freshDials > inFlight,
        reason: 'the next tick never dialled fresh',
      );
      expect(held.joins, 0);

      // Landing a fresh dial upgrades the route, and the adopted dial is kept.
      held.release.complete();
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the fresh dial did not upgrade the route',
      );
      await _settle(30);

      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
      expect(held.joins, 0);
      expect(
        held.disconnectCalls.length,
        2,
        reason: 'an adopted dial was torn down',
      );
    },
  );

  test(
    'after a failover to BLE the budget still tears the abandoned dial down',
    () async {
      await tcp.dispose();
      final held = _JoiningTcp()
        ..registerEndpoint(
          WmrWsEndpoint(host: '127.0.0.1', port: 8765, deviceId: _tcpDeviceId),
        )
        ..scanResults.add(tcpScanResult());
      held.hellos[_tcpDeviceId] = WmrWsHello(
        protocol: 1,
        transport: 'tcp',
        device: _tcpDeviceId,
        version: '0.2.4',
        hostname: 'wmrpi',
        authRequired: false,
        streams: const {'raw', 'decoded', 'batched'},
        recordSize: 56,
        batchMax: 9,
        fragmentCapacity: 46,
      );
      tcp = held;
      ble.dispose();
      ble = newBle();

      final transport = CompositeBleTransport(
        tcp: held,
        ble: ble,
        tcpProbeBudget: const Duration(milliseconds: 150),
        upgradeInterval: const Duration(milliseconds: 10),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      // The first dial lands, so the route is live on TCP before it drops.
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

      // The TCP leg drops: the failover lands on BLE and leaves the old
      // candidate named in `route.tcpDeviceId` behind.
      await _settle();
      held.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'the TCP drop did not fail over to BLE',
      );
      final failoverTearDowns = held.disconnectCalls.length;

      // Every upgrade tick dials the stale candidate again. Hold each one so
      // it hits the budget: the abandoned dial must be torn down — the stale
      // `tcpDeviceId` must not read as adoption — and the next tick must dial
      // fresh instead of joining the abandoned session.
      held.hold(_tcpDeviceId);
      await _waitFor(
        () => held.disconnectCalls.length > failoverTearDowns,
        reason: 'the abandoned dial outlived the budget after the failover',
      );
      await _waitFor(
        () => held.freshDials >= 3,
        reason:
            'a later tick joined the abandoned dial instead of dialling'
            ' fresh',
      );
      expect(held.joins, 0);
    },
  );

  test('after a failed switch rolls back to BLE the budget still tears the'
      ' abandoned dial down', () async {
    await tcp.dispose();
    final held = _JoiningTcp()
      ..registerEndpoint(
        WmrWsEndpoint(host: '127.0.0.1', port: 8765, deviceId: _tcpDeviceId),
      )
      ..scanResults.add(tcpScanResult());
    held.hellos[_tcpDeviceId] = WmrWsHello(
      protocol: 1,
      transport: 'tcp',
      device: _tcpDeviceId,
      version: '0.2.4',
      hostname: 'wmrpi',
      authRequired: false,
      streams: const {'raw', 'decoded', 'batched'},
      recordSize: 56,
      batchMax: 9,
      fragmentCapacity: 46,
    );
    tcp = held;

    ble.dispose();
    final stuck = _StuckDetachBle(
      devices: const [
        FakeDevice(
          id: _bleDeviceId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
      ],
      characteristic: wmrBridgeBatchedCharUuid,
    );
    stuck.onRead = (deviceId, characteristicUuid) {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        return _versionString();
      }
      throw StateError('unexpected read $characteristicUuid');
    };
    ble = stuck;

    final transport = CompositeBleTransport(
      tcp: held,
      ble: ble,
      tcpProbeBudget: const Duration(milliseconds: 150),
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    // The first dial lands, so the route is live on TCP before it drops.
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

    // A live channel gives the later switch something to fail on, and
    // the failing release is armed before the leg drops.
    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);
    stuck.failCancel = true;

    // The TCP leg drops: the failover lands on BLE. The settle lets the
    // state stream's forwarding subscription establish, so the drop's
    // event reaches the route.
    await _settle();
    held.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'the TCP drop did not fail over to BLE',
    );

    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);

    // The next upgrade dial lands, but the switch that activates TCP
    // fails partway: the route rolls back to BLE, and the landed session
    // stays behind with the transport.
    await _waitFor(
      () => stuck.stuckSubs.length >= 2,
      reason: 'the failed switch never rolled back to BLE',
    );

    // The landed session dies while the route is on BLE. The rollback
    // and the silent loss must both leave no `tcpDeviceId` behind, or
    // the teardown guard below would read the dead candidate as
    // adopted.
    final joinsAfterRollback = held.joins;
    final freshAfterDrop = held.freshDials;
    held.drop(_tcpDeviceId);
    // Every upgrade tick dials the candidate again. Hold each one so it
    // hits the budget: the abandoned dial must be torn down and the next
    // tick must dial fresh instead of joining the abandoned session.
    held.hold(_tcpDeviceId);
    final tearDowns = held.disconnectCalls.length;
    await _waitFor(
      () => held.disconnectCalls.length > tearDowns,
      reason: 'the abandoned dial outlived the budget after the rollback',
    );
    await _waitFor(
      () => held.freshDials >= freshAfterDrop + 3,
      reason:
          'a later tick joined the abandoned dial instead of dialling'
          ' fresh',
    );
    expect(held.joins, joinsAfterRollback);
    expect(
      transport.activeLegFor(_tcpDeviceId),
      CompositeLeg.ble,
      reason: 'the silent leg drop disconnected the route',
    );
    expect(
      states,
      isNot(contains(BleConnectionState.disconnected)),
      reason: 'the rollback or the silent drop reported a loss',
    );

    // Let the release succeed again so the teardown cancels cleanly.
    stuck.failCancel = false;
  });

  test('a probe that finishes while a BLE-drop recovery adopts its socket keeps it open', () async {
    await tcp.dispose();
    final held = _HeldDialTcp()
      ..registerEndpoint(
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: 8765,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      )
      ..scanResults.add(tcpScanResult());
    tcp = held;

    final transport = CompositeBleTransport(
      tcp: held,
      ble: ble,
      tcpProbeBudget: const Duration(milliseconds: 500),
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
    await _waitFor(
      () => held.disconnectCalls.isNotEmpty,
      reason: 'the connect-path dial outlived its budget',
    );

    // The upgrade probe dials fresh after the budget tore the connect-path
    // dial down. Then the BLE drop starts a recovery that joins that same
    // in-flight dial, so both are still awaiting when it lands. The recovery
    // adopts the socket; the probe must not close it.
    await _waitFor(
      () => held.dialAttempts >= 2,
      reason: 'the upgrade probe never dialled again after the teardown',
    );
    final attemptsBeforeDrop = held.dialAttempts;
    unawaited(ble.disconnect(_bleDeviceId));
    await _waitFor(
      () => held.dialAttempts > attemptsBeforeDrop,
      reason: 'the BLE drop never started a recovery dial',
    );
    held.release.complete();
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'the recovery did not adopt the fresh dial',
    );
    await _settle(50);

    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
    expect(
      held.disconnectCalls.length,
      1,
      reason: 'the probe closed the socket that the recovery adopted',
    );
  });

  test('closes the probe socket for a second candidate when another one is adopted', () async {
    const hostA = '192.168.1.50';
    const hostB = '127.0.0.1';
    const idA = '$hostA:$wmrWsDefaultPort';
    const idB = '$hostB:$wmrWsDefaultPort';
    await tcp.dispose();
    final joining = _JoiningTcp()..scanResults.add(tcpScanResult());
    tcp = joining;
    joining.hold(idA);
    joining.hold(idB);
    ble.dispose();
    ble = newBle(ff16: _endpointDocument(hosts: const [hostA, hostB]));

    final transport = CompositeBleTransport(
      tcp: joining,
      ble: ble,
      tcpProbeBudget: const Duration(milliseconds: 400),
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

    // The probe spends its first slice on the first candidate and times out;
    // the budget tears that abandoned dial down, and its second dial is the
    // one held here.
    await _waitFor(
      () => joining.dials.contains(idB),
      reason: 'the probe never dialled the second candidate',
    );
    await _waitFor(
      () => joining.disconnectCalls.contains(idA),
      reason: 'the abandoned first-candidate dial outlived its slice',
    );
    unawaited(ble.disconnect(_bleDeviceId));
    await _waitFor(
      () => joining.dials.where((id) => id == idA).length >= 2,
      reason: 'the BLE-drop recovery never dialled the first candidate again',
    );

    // Land the probe's own candidate while the recovery still holds the
    // route, then let the recovery adopt the other candidate.
    joining.holds[idB]!.complete();
    await _settle(10);
    joining.holds[idA]!.complete();
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'the recovery did not adopt the first candidate',
    );
    await _waitFor(
      () => joining.disconnectCalls.contains(idB),
      reason: 'the probe left its unused socket open',
    );
    await _settle(30);

    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.tcp);
    expect(
      joining.disconnectCalls.where((id) => id == idB).length,
      1,
      reason: 'the unused probe socket must be closed exactly once',
    );
    expect(
      joining.disconnectCalls.where((id) => id == idA).length,
      1,
      reason:
          'the abandoned dial must be torn down once and the adopted one kept',
    );
  });

  test('closes a never-adopted probe socket exactly once', () async {
    const hostA = '127.0.0.1';
    const idA = '$hostA:$wmrWsDefaultPort';
    await tcp.dispose();
    final joining = _JoiningTcp()..scanResults.add(tcpScanResult());
    tcp = joining;
    joining.hold(idA);
    ble.dispose();
    ble = newBle(ff16: _endpointDocument(hosts: const [hostA]));

    final transport = CompositeBleTransport(
      tcp: joining,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);
    await _waitFor(
      () => joining.dials.contains(idA),
      reason: 'the upgrade probe never dialled',
    );

    // The route is torn down while the probe is in flight, so neither a
    // switch nor the route ever adopts the socket.
    await transport.dispose();
    joining.holds[idA]!.complete();
    await _waitFor(
      () => joining.disconnectCalls.contains(idA),
      reason: 'the never-adopted socket was left open',
    );
    await _settle(30);

    expect(
      joining.disconnectCalls.where((id) => id == idA).length,
      1,
      reason: 'the socket must be closed once, not again by the dial cleanup',
    );
  });

  test('a connect after a lost route dials fresh and adopts it', () async {
    const hostA = '127.0.0.1';
    const idA = '$hostA:$wmrWsDefaultPort';
    await tcp.dispose();
    final joining = _JoiningTcp()..scanResults.add(tcpScanResult());
    tcp = joining;
    joining.hold(idA);
    ble.dispose();
    ble = newBle(ff16: _endpointDocument(hosts: const [hostA]));

    final transport = CompositeBleTransport(
      tcp: joining,
      ble: ble,
      tcpProbeBudget: const Duration(milliseconds: 40),
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);
    await _waitFor(
      () => joining.dials.isNotEmpty,
      reason: 'the upgrade probe never dialled',
    );

    // The BLE drop starts a recovery that joins the same held dial. The probe
    // leaves it alone — the recovery's dial owns the candidate — and when
    // the recovery's own budget expires it tears the abandoned dial down, so
    // the route loses both legs.
    unawaited(ble.disconnect(_bleDeviceId));
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == null,
      reason: 'the route never lost both legs',
    );
    expect(joining.disconnectCalls, [idA]);

    final dialsBefore = joining.dials.length;
    final reconnect = transport.connect(_bleDeviceId);
    await _waitFor(
      () => joining.dials.length > dialsBefore,
      reason: 'the connect never dialled',
    );
    joining.holds[idA]!.complete();
    await reconnect;
    await _settle(30);

    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.tcp);
    expect(
      joining.disconnectCalls,
      [idA],
      reason: 'the abandoned dial was left open or the adopted one was closed',
    );
  });

  test('a TCP activation that fails partway rolls back to BLE', () async {
    ble.dispose();
    final stuck = _StuckDetachBle(
      devices: const [
        FakeDevice(
          id: _bleDeviceId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
      ],
      characteristic: wmrBridgeBatchedCharUuid,
    );
    stuck.onRead = (deviceId, characteristicUuid) {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        return _versionString();
      }
      throw StateError('unexpected read $characteristicUuid');
    };
    ble = stuck;
    tcp.failConnect = true;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);
    expect(stuck.deliverStuck([1]), isTrue, reason: 'the BLE leg is silent');
    await _settle();
    expect(received.last.value, [1]);

    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);

    // The upgrade dial lands, but the switch that activates TCP fails
    // partway: the BLE notification release refuses.
    stuck.failCancel = true;
    tcp.failConnect = false;
    await _settle(60);

    expect(
      transport.activeLegFor(_tcpDeviceId),
      CompositeLeg.ble,
      reason: 'the failed switch did not leave the route on BLE',
    );
    expect(
      states,
      isNot(contains(BleConnectionState.disconnected)),
      reason: 'the rollback reported a loss',
    );
    // The rollback re-subscribed the channel on BLE; it still delivers.
    expect(
      stuck.deliverStuck([2]),
      isTrue,
      reason: 'the channel stayed half-attached to the failed switch',
    );
    await _settle();
    expect(received.last.value, [2]);
    expect(
      tcp.connectCalls.length,
      greaterThan(2),
      reason: 'the upgrade timer did not resume',
    );
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['upgrade_outcome'] ==
          'activation_threw',
      reason: 'the failed activation never recorded its outcome',
    );

    // Let the release succeed again so the teardown cancels cleanly.
    stuck.failCancel = false;
  });

  test('a switch that fails after the echo handoff still drains the orphaned'
      ' subscription', () async {
    ble.dispose();
    final fake = _FailingSwitchBle(
      devices: const [
        FakeDevice(
          id: _bleDeviceId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
      ],
      failCharacteristic: wmrBridgeBatchedCharUuid,
      trackCharacteristic: wmrBridgeEchoCharUuid,
    );
    fake.onRead = (deviceId, characteristicUuid) {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        return _versionString();
      }
      throw StateError('unexpected read $characteristicUuid');
    };
    ble = fake;
    tcp.failConnect = true;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
      echoDrainTimeout: const Duration(milliseconds: 60),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    final states = <BleConnectionState>[];
    final stateSub = transport.connectionState(_tcpDeviceId).listen(states.add);
    addTearDown(stateSub.cancel);

    // The echo channel is subscribed first, so the switch hands it off to
    // the drain before the batched channel's release fails. Its ping is in
    // flight, which is why the subscription is kept at all.
    final echoReceived = <BleNotification>[];
    final echoSub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
        .listen(echoReceived.add);
    addTearDown(echoSub.cancel);
    final batchedSub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen((_) {});
    addTearDown(batchedSub.cancel);
    await transport.write(
      _tcpDeviceId,
      wmrBridgeServiceUuid,
      wmrBridgeEchoCharUuid,
      Uint8List.fromList([1, 39, 0, 0, 0, 0]),
      withoutResponse: true,
    );

    // The upgrade dial lands; the switch fails partway: the echo
    // subscription was handed off, then the batched release refuses.
    fake.failCancel = true;
    tcp.failConnect = false;
    await _waitFor(
      () => fake.tracked.length >= 2,
      reason: 'the failed switch never handed the echo subscription off',
    );
    expect(
      transport.activeLegFor(_tcpDeviceId),
      CompositeLeg.ble,
      reason: 'the failed switch did not roll back to BLE',
    );

    // The orphaned handoff must still drain: its subscription is cancelled
    // once the drain window expires, not left beside the re-attach.
    await _waitFor(
      () => fake.cancelledSubscriptions >= 1,
      reason: 'the handed-off echo subscription was orphaned',
    );

    // The rollback re-attached the channel on BLE; it still delivers.
    tcp.failConnect = true;
    await _settle(30);
    expect(fake.deliverTracked([7]), isTrue);
    await _settle();
    expect(echoReceived.last.value, [7]);
    expect(
      states,
      isNot(contains(BleConnectionState.disconnected)),
      reason: 'the rollback reported a loss',
    );

    // Let the release succeed again so the teardown cancels cleanly.
    fake.failCancel = false;
  });

  test('kicks the FF16 upgrade once a TCP-to-BLE failover lands on BLE', () async {
    ble.dispose();
    ble = newBle(ff16: _endpointDocument());
    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(hours: 1),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

    final dialsBeforeFailover = tcp.connectCalls.length;
    // Let the TCP state listener attach before the drop.
    await _settle();
    tcp.drop(_tcpDeviceId);
    // The timer is an hour away, so only the kick after the failover can dial.
    await _waitFor(
      () => tcp.connectCalls.length > dialsBeforeFailover,
      reason: 'the FF16 upgrade was not kicked after the failover',
    );
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'the kicked upgrade did not move the route back to TCP',
    );
  });

  test(
    'does not dial a TCP probe while a BLE-drop failover holds the route',
    () async {
      tcp.failConnect = true;
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
        tcpProbeBudget: const Duration(milliseconds: 200),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
      await _settle(30);

      // The next TCP dial hangs, so the failover's recovery dial holds the
      // route in its switching window while the upgrade timer keeps ticking.
      tcp.hangConnect = true;
      final before = tcp.connectCalls.length;
      unawaited(ble.disconnect(_bleDeviceId));
      await _waitFor(
        () => tcp.connectCalls.length > before,
        reason: 'the failover did not dial TCP',
      );
      final dialed = tcp.connectCalls.length;
      await _settle(80);
      expect(
        tcp.connectCalls.length,
        dialed,
        reason:
            'an upgrade probe dialled TCP while the failover held the route',
      );
    },
  );

  test('closes a TCP probe that lands after an explicit disconnect', () async {
    await tcp.dispose();
    final held = _HoldableTcp()
      ..failConnect = true
      ..registerEndpoint(
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: 8765,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      )
      ..scanResults.add(tcpScanResult());
    tcp = held;

    final transport = CompositeBleTransport(
      tcp: held,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    // Hold the next upgrade dial in flight, then tear the route down under it.
    held.failConnect = false;
    held.holdDials = Completer<void>();
    await _waitFor(
      () => held.heldDials > 0,
      reason: 'the upgrade probe never dialled',
    );
    await transport.disconnect(_tcpDeviceId);

    held.holdDials!.complete();
    await _waitFor(
      () => held.disconnectCalls.contains(_tcpDeviceId),
      reason: 'the late probe socket was left open',
    );
    expect(transport.activeLegFor(_tcpDeviceId), isNull);
  });

  test('an upgrade dial the LAN gate skips records dial_skipped', () async {
    tcp.failConnect = true;
    var lan = true;
    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      lanAvailable: () async => lan,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
    lan = false;
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['upgrade_outcome'] ==
          'dial_skipped',
      reason: 'the skipped dial never recorded its outcome',
    );
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);
  });

  test('an explicit disconnect during an upgrade dial records route_moved'
      ' and keeps the timeline readable', () async {
    await tcp.dispose();
    final held = _HoldableTcp()
      ..failConnect = true
      ..registerEndpoint(
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: 8765,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      )
      ..scanResults.add(tcpScanResult());
    tcp = held;
    final transport = CompositeBleTransport(
      tcp: held,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    held.failConnect = false;
    held.holdDials = Completer<void>();
    await _waitFor(
      () => held.heldDials > 0,
      reason: 'the upgrade probe never dialled',
    );
    await transport.disconnect(_tcpDeviceId);
    held.holdDials!.complete();
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)?['upgrade_outcome'] ==
          'route_moved',
      reason: 'the in-flight attempt never recorded its terminal outcome',
    );
  });

  test(
    'releases a BLE link whose connect fails in the initial candidate loop',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      final refusing = _RecordingBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
      )..refusedConnects.add(_bleDeviceId);
      refusing.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _versionString();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      ble = refusing;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
      );
      addTearDown(transport.dispose);
      await transport.scan().toList();

      await expectLater(
        transport.connect(_tcpDeviceId),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'ble connect refused',
          ),
        ),
      );
      expect(refusing.disconnectCalls, [_bleDeviceId]);
      expect(transport.activeLegFor(_tcpDeviceId), isNull);
    },
  );

  test(
    'releases a BLE link whose connect fails in the failover candidate loop',
    () async {
      ble.dispose();
      final refusing = _RecordingBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
      );
      refusing.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _versionString();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      ble = refusing;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
      );
      addTearDown(transport.dispose);
      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

      refusing.refusedConnects.add(_bleDeviceId);
      // Let the TCP state listener attach before the drop.
      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => refusing.disconnectCalls.contains(_bleDeviceId),
        reason: 'the refused BLE link was not released',
      );
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == null,
        reason: 'the failed failover did not release the route',
      );
      expect(refusing.disconnectCalls, [_bleDeviceId]);
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(marks['failover_outcome'], 'lost');
      expect(marks['failover_reason'], 'connect_threw');
      expect(marks['failover_candidate_count'], 1);
    },
  );

  test(
    'a failover whose first candidate refuses lands on the next one',
    () async {
      ble.dispose();
      const otherId = 'AA:BB:CC:DD:EE:02';
      final two = _RecordingBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
          FakeDevice(
            id: otherId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
      );
      two.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _endpointDocument();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      ble = two;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
      );
      addTearDown(transport.dispose);
      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
      two.refusedConnects.add(_bleDeviceId);
      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () =>
            transport.linkTimelineFor(_tcpDeviceId)!['failover_end_us'] != null,
        reason: 'the failover did not land on the second candidate',
      );
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(marks['failover_outcome'], isNot('lost'));
      expect(marks['failover_candidate_count'], 2);
      expect(two.disconnectCalls, contains(_bleDeviceId));
    },
  );

  test(
    'a failover with no BLE bridge to dial ends lost with no candidate',
    () async {
      ble.dispose();
      final empty = _RecordingBle(devices: const []);
      ble = empty;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
      );
      addTearDown(transport.dispose);
      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == null,
        reason: 'the failover with no BLE bridge did not release the route',
      );
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(marks['failover_outcome'], 'lost');
      expect(marks['failover_reason'], 'no_candidate');
      expect(marks['failover_candidate_count'], 0);
    },
  );

  test(
    'an app redial after a lost failover is a recovery, not an attempt',
    () async {
      ble.dispose();
      ble = _RecordingBle(devices: const []);
      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
      );
      addTearDown(transport.dispose);
      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      await _settle();
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == null,
        reason: 'the failover with no BLE bridge did not release the route',
      );
      expect(transport.linkTimelineFor(_tcpDeviceId)!['recovery_lane'], isNull);

      await transport.connect(_tcpDeviceId);

      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
      expect(marks['recovery_lane'], 'redial');
      expect(marks['recovery_us'], isNotNull);
      expect(marks['upgrade_dial_attempts'], 0);
      expect(marks['failover_end_us'], isNull);
      expect(marks['upgrade_outcome'], isNull);
    },
  );

  for (final late in [true, false]) {
    test(
      late
          ? 'a failover waits for a late scan hit, lands BLE and dials once'
          : 'a failover whose scan never hits ends lost with no_candidate',
      () async {
        ble.dispose();
        final gated = _GatedScanBle(
          devices: const [
            FakeDevice(
              id: _bleDeviceId,
              name: 'WMR Bridge',
              services: fakeBridgeDeviceServices,
            ),
          ],
          results: [
            BleScanResult(
              deviceId: _bleDeviceId,
              name: 'WMR Bridge',
              rssi: -40,
              serviceUuids: const [wmrBridgeServiceUuid],
            ),
          ],
        );
        gated.onRead = (deviceId, characteristicUuid) {
          if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
            return _endpointDocument();
          }
          throw StateError('unexpected read $characteristicUuid');
        };
        ble = gated;
        final transport = CompositeBleTransport(
          tcp: tcp,
          ble: ble,
          upgradeInterval: const Duration(milliseconds: 200),
          bleScanWait: late
              ? const Duration(seconds: 5)
              : const Duration(milliseconds: 30),
        );
        addTearDown(transport.dispose);
        final sub = transport.scan().listen((_) {});
        addTearDown(sub.cancel);
        await _settle();
        await transport.connect(_tcpDeviceId);
        expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

        await _settle();
        tcp.hangConnect = true;
        tcp.drop(_tcpDeviceId);
        await _settle();
        // Parked on the scan wait: neither landed nor lost yet.
        expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
        if (late) {
          gated.finishScan();
          await _waitFor(
            () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
            reason: 'the late scan hit never landed BLE',
          );
          final marks = transport.linkTimelineFor(_tcpDeviceId)!;
          expect(marks['failover_end_us'], isNotNull);
          await _waitFor(
            () =>
                transport.linkTimelineFor(
                  _tcpDeviceId,
                )!['upgrade_dial_attempts'] ==
                1,
            reason: 'the landed failover did not run one dial attempt',
          );
        } else {
          await _waitFor(
            () => transport.activeLegFor(_tcpDeviceId) == null,
            reason: 'the empty wait did not release the route',
          );
          final marks = transport.linkTimelineFor(_tcpDeviceId)!;
          expect(marks['failover_outcome'], 'lost');
          expect(marks['failover_reason'], 'no_candidate');
        }
      },
    );
  }

  test('a failover whose BLE activation throws ends lost with '
      'activation_threw', () async {
    ble.dispose();
    final bridge =
        _RecordingBle(
            devices: const [
              FakeDevice(
                id: _bleDeviceId,
                name: 'WMR Bridge',
                services: fakeBridgeDeviceServices,
              ),
            ],
          )
          ..onRead = (deviceId, characteristicUuid) {
            if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
              return _endpointDocument();
            }
            throw StateError('unexpected read $characteristicUuid');
          };
    ble = bridge;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: Duration.zero,
      bleScanWait: Duration.zero,
    );
    addTearDown(transport.dispose);
    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

    // A live TCP channel must release its subscription when the switch
    // leaves TCP; that release fails, so the BLE activation throws.
    tcp.failCancel = true;
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen((_) {});
    addTearDown(sub.cancel);
    await _settle();
    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == null,
      reason: 'the failed activation did not release the route',
    );
    final marks = transport.linkTimelineFor(_tcpDeviceId)!;
    expect(marks['failover_outcome'], 'lost');
    expect(marks['failover_reason'], 'activation_threw');
    expect(marks['failover_candidate_count'], 1);
  });

  test(
    'keeps the FF15 BLE subscription until an in-flight echo answer lands',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      ble = newBle(ff16: _endpointDocument());
      tcp.scanResults
        ..clear()
        ..add(tcpScanResult());
      tcp.hellos.clear();

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
        echoDrainTimeout: const Duration(seconds: 1),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
          .listen(received.add);
      addTearDown(sub.cancel);

      // The ping is written on BLE just before the upgrade. Its answer can only
      // arrive while the bridge's FF15 CCCD is still on.
      final ping = Uint8List.fromList([1, 39, 0, 0, 0, 0]);
      await transport.write(
        _tcpDeviceId,
        wmrBridgeServiceUuid,
        wmrBridgeEchoCharUuid,
        ping,
        withoutResponse: true,
      );

      tcp.failConnect = false;
      tcp.endpoints.remove(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the BLE-to-TCP upgrade did not happen',
      );

      // The switch has landed, but the in-flight answer keeps FF15 on BLE.
      expect(
        ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid),
        isTrue,
        reason: 'the BLE FF15 subscription was cancelled during the switch',
      );
      expect(
        ble.cccLog,
        isNot(contains('off $wmrBridgeEchoCharUuid')),
        reason: 'the FF15 CCCD was turned off before the answer landed',
      );

      final answer = Uint8List.fromList([1, 39, 0, 1, 2, 3]);
      expect(ble.emit(_bleDeviceId, wmrBridgeEchoCharUuid, answer), isTrue);
      await _settle();
      expect(received.last.value, orderedEquals(answer));
      expect(tcp.emit(_lanDeviceId, wmrBridgeEchoCharUuid, answer), isTrue);

      // The answer drained, so the kept BLE subscription and its CCCD go now.
      await _waitFor(
        () => !ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid),
        reason: 'the kept FF15 BLE subscription never drained',
      );
      expect(ble.cccLog, contains('off $wmrBridgeEchoCharUuid'));
    },
  );

  test(
    'cancels the kept FF15 BLE subscription when the answer never lands',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      ble = newBle(ff16: _endpointDocument());
      tcp.scanResults
        ..clear()
        ..add(tcpScanResult());

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
        echoDrainTimeout: const Duration(milliseconds: 80),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      final sub = transport
          .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
          .listen((_) {});
      addTearDown(sub.cancel);
      await transport.write(
        _tcpDeviceId,
        wmrBridgeServiceUuid,
        wmrBridgeEchoCharUuid,
        Uint8List.fromList([1, 39, 0, 0, 0, 0]),
        withoutResponse: true,
      );

      tcp.failConnect = false;
      tcp.endpoints.remove(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the BLE-to-TCP upgrade did not happen',
      );
      expect(ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid), isTrue);
      // The bridge never answers, so the drain window must release FF15.
      await _waitFor(
        () => !ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid),
        reason: 'the drain timeout left the FF15 BLE subscription on',
      );
      expect(ble.cccLog, contains('off $wmrBridgeEchoCharUuid'));
    },
  );

  test(
    'suspending the streams drops an FF15 drain without a second CCCD off',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      ble = _CccdBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
      );
      ble.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _endpointDocument();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      tcp.scanResults
        ..clear()
        ..add(tcpScanResult());

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
        echoDrainTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      final first = transport
          .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
          .listen((_) {});
      addTearDown(first.cancel);
      await transport.write(
        _tcpDeviceId,
        wmrBridgeServiceUuid,
        wmrBridgeEchoCharUuid,
        Uint8List.fromList([1, 39, 0, 0, 0, 0]),
        withoutResponse: true,
      );

      tcp.failConnect = false;
      tcp.endpoints.remove(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'the BLE-to-TCP upgrade did not happen',
      );
      // The FF15 drain is still inside its window when the host moves the
      // bridge to Wi-Fi.
      expect(ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid), isTrue);

      await transport.suspendBleStreams(_tcpDeviceId);
      expect(
        ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid),
        isFalse,
        reason: 'suspend left the pending FF15 drain subscribed',
      );

      // The drain was dropped with the streams; its window expiring must not
      // turn the CCCD off a second time.
      ble.cccLog.clear();
      await _settle(250);
      expect(
        ble.cccLog,
        isNot(contains('off $wmrBridgeEchoCharUuid')),
        reason: 'the dropped drain turned the FF15 CCCD off a second time',
      );
    },
  );

  test('a TCP-lane FF15 answer does not end the kept BLE drain', () async {
    tcp.failConnect = true;
    ble.dispose();
    ble = newBle(ff16: _endpointDocument());
    tcp.scanResults
      ..clear()
      ..add(tcpScanResult());

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
      echoDrainTimeout: const Duration(seconds: 5),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
        .listen((_) {});
    addTearDown(sub.cancel);
    await transport.write(
      _tcpDeviceId,
      wmrBridgeServiceUuid,
      wmrBridgeEchoCharUuid,
      Uint8List.fromList([1, 39, 0, 0, 0, 0]),
      withoutResponse: true,
    );

    tcp.failConnect = false;
    tcp.endpoints.remove(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'the BLE-to-TCP upgrade did not happen',
    );

    // An answer that arrived over TCP says nothing about the BLE reply still
    // in flight, so the kept BLE subscription must survive it.
    expect(
      tcp.emit(
        _lanDeviceId,
        wmrBridgeEchoCharUuid,
        Uint8List.fromList([1, 39, 0, 1, 2, 3]),
      ),
      isTrue,
    );
    await _settle();
    expect(
      ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid),
      isTrue,
      reason: 'a TCP-lane answer drained the kept BLE subscription',
    );

    expect(
      ble.emit(
        _bleDeviceId,
        wmrBridgeEchoCharUuid,
        Uint8List.fromList([1, 39, 0, 1, 2, 3]),
      ),
      isTrue,
    );
    await _waitFor(
      () => !ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid),
      reason: 'the BLE-lane answer did not drain the kept subscription',
    );
  });

  test('drains both FF15 handoffs when the route leaves BLE twice before the answer lands', () async {
    tcp.failConnect = true;
    ble.dispose();
    final cccdBle = _CccdBle(
      devices: const [
        FakeDevice(
          id: _bleDeviceId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
      ],
    );
    cccdBle.onRead = (deviceId, characteristicUuid) {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        return _endpointDocument();
      }
      throw StateError('unexpected read $characteristicUuid');
    };
    ble = cccdBle;
    tcp.scanResults
      ..clear()
      ..add(tcpScanResult());

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: cccdBle,
      upgradeInterval: const Duration(milliseconds: 10),
      echoDrainTimeout: const Duration(seconds: 5),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);
    await transport.write(
      _tcpDeviceId,
      wmrBridgeServiceUuid,
      wmrBridgeEchoCharUuid,
      Uint8List.fromList([1, 39, 0, 0, 0, 0]),
      withoutResponse: true,
    );

    tcp.failConnect = false;
    tcp.endpoints.remove(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'the BLE-to-TCP upgrade did not happen',
    );

    // The TCP leg drops before the answer lands. The route fails over to BLE
    // and the FF16 kick upgrades it again, so a second FF15 handoff starts
    // while the first drain is still waiting.
    final ons = cccdBle.cccLog
        .where((entry) => entry == 'on $wmrBridgeEchoCharUuid')
        .length;
    final tcpEchoKey = '$_lanDeviceId|$wmrBridgeEchoCharUuid';
    tcp.drop(_lanDeviceId);
    await _waitFor(
      () =>
          cccdBle.cccLog
                  .where((entry) => entry == 'on $wmrBridgeEchoCharUuid')
                  .length >
              ons &&
          (tcp.streams[tcpEchoKey]?.hasListener ?? false),
      reason: 'the route did not fail over to BLE and upgrade again',
    );

    expect(
      ble.emit(
        _bleDeviceId,
        wmrBridgeEchoCharUuid,
        Uint8List.fromList([1, 39, 0, 1, 2, 3]),
      ),
      isTrue,
    );
    await _waitFor(
      () => !ble.isSubscribed(_bleDeviceId, wmrBridgeEchoCharUuid),
      reason: 'a handed-off FF15 subscription leaked after the second switch',
    );
    expect(ble.cccLog, contains('off $wmrBridgeEchoCharUuid'));
    expect(
      received,
      hasLength(1),
      reason:
          'the kept drain and the re-attached subscription both forwarded '
          'the same FF15 answer',
    );
  });

  test(
    'leaves a socket alone while a newer dial still owns the candidate',
    () async {
      await tcp.dispose();
      final split = _SplitDialTcp()
        ..failConnect = true
        ..registerEndpoint(
          WmrWsEndpoint(
            host: '127.0.0.1',
            port: 8765,
            deviceId: _tcpDeviceId,
            bridgeId: _bridgeId,
          ),
        )
        ..endpoints.remove(_tcpDeviceId)
        ..scanResults.add(tcpScanResult());
      tcp = split;
      ble.dispose();
      ble = newBle(ff16: _endpointDocument());

      final transport = CompositeBleTransport(
        tcp: split,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
        tcpProbeBudget: const Duration(milliseconds: 400),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

      // The upgrade probe's dial hangs. A BLE drop then starts a recovery dial
      // on the same candidate: that newer dial owns the socket now.
      split
        ..failConnect = false
        ..holdDials = true;
      await _waitFor(
        () => split.holds.isNotEmpty,
        reason: 'the upgrade probe never dialled',
      );
      final probeDial = split.holds.single;
      unawaited(ble.disconnect(_bleDeviceId));
      await _waitFor(
        () => split.holds.length > 1,
        reason: 'the recovery never dialled',
      );
      probeDial.complete();

      // The recovery runs into its own budget and the route is lost. The probe
      // landed while the recovery dial still owned the candidate, so it must
      // leave that socket alone.
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == null,
        reason: 'the failed recovery did not release the route',
      );
      await _settle(50);
      expect(
        split.disconnectCalls,
        isEmpty,
        reason: 'the probe closed a socket a newer dial still owns',
      );
    },
  );

  test(
    'leaves its socket to a switch that still holds the route after dispose',
    () async {
      await tcp.dispose();
      final split = _SplitDialTcp()
        ..failConnect = true
        ..registerEndpoint(
          WmrWsEndpoint(
            host: '127.0.0.1',
            port: 8765,
            deviceId: _tcpDeviceId,
            bridgeId: _bridgeId,
          ),
        )
        ..endpoints.remove(_tcpDeviceId)
        ..scanResults.add(tcpScanResult());
      tcp = split;
      ble.dispose();
      ble = newBle(ff16: _endpointDocument());

      final transport = CompositeBleTransport(
        tcp: split,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
        tcpProbeBudget: const Duration(milliseconds: 400),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

      split
        ..failConnect = false
        ..holdDials = true;
      await _waitFor(
        () => split.holds.isNotEmpty,
        reason: 'the upgrade probe never dialled',
      );
      final probeDial = split.holds.single;
      unawaited(ble.disconnect(_bleDeviceId));
      await _waitFor(
        () => split.holds.length > 1,
        reason: 'the recovery never dialled',
      );

      // Disposing mid-switch leaves the route unsettled; the probe that lands
      // afterwards must not judge a socket the switch may still adopt.
      await transport.dispose();
      probeDial.complete();
      await _settle(50);
      expect(
        split.disconnectCalls,
        isEmpty,
        reason: 'the probe closed its socket after a dispose during a switch',
      );
    },
  );

  test('Transition 6: multi-candidate upgrade and BLE-drop recovery dial the '
      'previously active TCP candidate first', () async {
    const deadHost = '192.168.1.50';
    const liveHost = '127.0.0.1';
    final deadId = '$deadHost:$wmrWsDefaultPort';
    final liveId = '$liveHost:$wmrWsDefaultPort';
    await tcp.dispose();
    final refusing = _RefusingTcp({deadId})..scanResults.add(tcpScanResult());
    tcp = refusing;
    ble.dispose();
    ble = newBle(ff16: _endpointDocument(hosts: const [deadHost, liveHost]));

    var lan = true;
    final transport = CompositeBleTransport(
      tcp: refusing,
      ble: ble,
      lanAvailable: () async => lan,
      upgradeInterval: const Duration(milliseconds: 20),
      upgradeRetryDelay: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'initial upgrade to liveId did not land',
    );

    // Failover to BLE clears route.tcpDeviceId; hold LAN gate while failing
    // over so no upgrade dial starts before we clear dialAt.
    lan = false;
    refusing.refusing.add(liveId);
    refusing.drop(liveId);
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.ble,
      reason: 'route did not fail over to BLE',
    );

    refusing.dialAt.clear();
    refusing.refusing.remove(liveId);
    lan = true;
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'upgrade did not land back on TCP',
    );
    expect(refusing.dialAt.map((e) => e.key), [
      liveId,
    ], reason: '_attemptUpgrade did not prioritize lastWorkingTcpDeviceId');

    // Failover to BLE again, then drop BLE so _recoverFromBleDrop runs:
    // it must also dial liveId first without touching deadId.
    lan = false;
    refusing.refusing.add(liveId);
    refusing.drop(liveId);
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.ble,
      reason: 'second failover to BLE did not land',
    );

    refusing.dialAt.clear();
    refusing.refusing.remove(liveId);
    lan = true;
    unawaited(ble.disconnect(_bleDeviceId));
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'BLE-drop recovery did not land on TCP',
    );
    expect(refusing.dialAt.map((e) => e.key), [
      liveId,
    ], reason: '_recoverFromBleDrop did not prioritize lastWorkingTcpDeviceId');
  });

  test('Transition 7: secondary candidate lands when primary stays down, and '
      'outage holds BLE continuity with zero leaked channels', () async {
    const hostA = '192.168.1.50';
    const hostB = '127.0.0.1';
    final idA = '$hostA:$wmrWsDefaultPort';
    final idB = '$hostB:$wmrWsDefaultPort';
    await tcp.dispose();
    final refusing = _RefusingTcp({idA})..scanResults.add(tcpScanResult());
    tcp = refusing;
    ble.dispose();
    ble = newBle(ff16: _endpointDocument(hosts: const [hostA, hostB]));

    var lan = true;
    final transport = CompositeBleTransport(
      tcp: refusing,
      ble: ble,
      lanAvailable: () async => lan,
      upgradeInterval: const Duration(milliseconds: 20),
      upgradeRetryDelay: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_bleDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'initial upgrade to idB did not land',
    );

    // Keep a live channel subscribed across failovers.
    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_bleDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);

    // Drop primary (idB) and keep both down: BLE continuity holds.
    refusing.refusing.addAll([idA, idB]);
    refusing.drop(idB);
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.ble,
      reason: 'route did not fail over to BLE',
    );
    await _waitFor(
      () =>
          (transport.linkTimelineFor(_bleDeviceId)?['upgrade_dial_attempts']
                  as int? ??
              0) >=
          1,
      reason: 'no upgrade attempt was counted',
    );
    expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

    // Pause LAN gate, bring secondary (idA) up while primary (idB) stays
    // down, then re-open LAN gate so the next pass records [idB, idA].
    lan = false;
    await _waitFor(
      () =>
          transport.linkTimelineFor(_bleDeviceId)?['upgrade_outcome'] ==
          'dial_skipped',
      reason: 'in-flight dial did not settle',
    );
    refusing.dialAt.clear();
    refusing.refusing.remove(idA);
    lan = true;
    await _waitFor(
      () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
      reason: 'secondary candidate idA never landed while primary was down',
    );
    expect(refusing.dialAt.map((e) => e.key), containsAll([idB, idA]));

    // Verify channel still delivers on the landed TCP leg.
    tcp.emit(idA, wmrBridgeBatchedCharUuid, Uint8List.fromList([7, 8]));
    await _waitFor(() => received.isNotEmpty);
    expect(received.last.value, [7, 8]);
  });

  test(
    'Transition 8: slow-but-healthy primary (160 ms) with 2 candidates lands '
    'in 1 pass inside 300 ms upgradeProbeBudget',
    () async {
      const deadHost = '192.168.1.50';
      const slowHost = '127.0.0.1';
      final slowId = '$slowHost:$wmrWsDefaultPort';
      await tcp.dispose();
      final slow = _SlowDialTcp(const Duration(milliseconds: 160))
        ..scanResults.add(tcpScanResult());
      tcp = slow;
      ble.dispose();
      ble = newBle(ff16: _endpointDocument(hosts: const [slowHost, deadHost]));

      final transport = CompositeBleTransport(
        tcp: slow,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 20),
        upgradeProbeBudget: const Duration(milliseconds: 300),
        tcpCandidateShareCap: const Duration(milliseconds: 250),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_bleDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
        reason: 'initial upgrade to slowId did not land',
      );

      slow.failConnect = true;
      slow.drop(slowId);
      await _waitFor(
        () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.ble,
        reason: 'route did not fail over to BLE',
      );

      slow.connectCalls.clear();
      slow.failConnect = false;
      await _waitFor(
        () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
        reason: 'slow primary (160 ms) was starved and failed to upgrade',
      );
      expect(slow.connectCalls, [
        slowId,
      ], reason: 'primary candidate did not land in 1 pass');
    },
  );

  test(
    'Transition 9: activation failure mid-dial rolls back to BLE and preserves '
    'remembered primary-candidate order',
    () async {
      const secondaryHost = '192.168.1.50';
      const primaryHost = '127.0.0.1';
      final secondaryId = '$secondaryHost:$wmrWsDefaultPort';
      final primaryId = '$primaryHost:$wmrWsDefaultPort';
      await tcp.dispose();
      final refusing = _RefusingTcp({secondaryId})
        ..scanResults.add(tcpScanResult());
      tcp = refusing;
      ble.dispose();
      final stuck = _StuckDetachBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
        characteristic: wmrBridgeBatchedCharUuid,
      );
      stuck.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _endpointDocument(hosts: const [secondaryHost, primaryHost]);
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      ble = stuck;

      var lan = true;
      final transport = CompositeBleTransport(
        tcp: refusing,
        ble: stuck,
        lanAvailable: () async => lan,
        upgradeInterval: const Duration(milliseconds: 20),
        upgradeRetryDelay: const Duration(milliseconds: 10),
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_bleDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.tcp,
        reason: 'initial upgrade to primaryId did not land',
      );

      // Fail over to BLE while LAN is gated.
      lan = false;
      refusing.refusing.add(primaryId);
      refusing.drop(primaryId);
      await _waitFor(
        () => transport.activeLegFor(_bleDeviceId) == CompositeLeg.ble,
        reason: 'route did not fail over to BLE',
      );

      // Subscribe a channel on _StuckDetachBle; its detach throws on cancel,
      // causing _activateTcp to throw activation_threw and roll back to BLE.
      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _bleDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add, onError: (_) {});
      addTearDown(sub.cancel);
      expect(stuck.deliverStuck([9]), isTrue);
      await _settle();
      expect(received.last.value, [9]);

      stuck.failCancel = true;
      refusing.refusing.remove(primaryId);
      refusing.dialAt.clear();
      lan = true;

      await _waitFor(
        () =>
            transport.linkTimelineFor(_bleDeviceId)?['upgrade_outcome'] ==
            'activation_threw',
        reason: 'activation failure never recorded activation_threw',
      );
      expect(transport.activeLegFor(_bleDeviceId), CompositeLeg.ble);

      // BLE lane still delivers after rollback, and primaryId is still tried
      // first on the subsequent attempt.
      expect(stuck.deliverStuck([10]), isTrue);
      await _waitFor(() => received.length >= 2);
      expect(received.last.value, [10]);
      expect(
        refusing.dialAt.first.key,
        primaryId,
        reason: 'primary-candidate order was lost after activation failure',
      );
      stuck.failCancel = false;
    },
  );

  test(
    'tcpReceipts emits immediately when first_tcp_record_us is stamped',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      ble = newBle(ff16: _endpointDocument());

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
      );
      addTearDown(transport.dispose);

      final receiptEvents = <String>[];
      final receiptSub = transport.tcpReceipts.listen(receiptEvents.add);
      addTearDown(receiptSub.cancel);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add);
      addTearDown(sub.cancel);

      tcp.failConnect = false;
      tcp.endpoints.remove(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'upgrade did not land on TCP',
      );
      expect(receiptEvents, isEmpty);

      tcp.emit(
        _lanDeviceId,
        wmrBridgeBatchedCharUuid,
        Uint8List.fromList([1, 2]),
      );
      await _waitFor(
        () => receiptEvents.isNotEmpty,
        reason: 'tcpReceipts did not emit when first_tcp_record_us was stamped',
      );
      expect(receiptEvents, [_tcpDeviceId]);
      final timeline = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(timeline['first_tcp_record_us'], isA<int>());
      expect(timeline['first_tcp_record_session'], _lanDeviceId);

      // A second TCP record in the same episode does not re-emit.
      tcp.emit(
        _lanDeviceId,
        wmrBridgeBatchedCharUuid,
        Uint8List.fromList([3, 4]),
      );
      await _settle(20);
      expect(receiptEvents, [_tcpDeviceId]);
    },
  );

  test('T1: healthy BLE -> TCP upgrade activates TCP without waiting on slow BLE unsubscribe', () async {
    tcp.failConnect = true;
    ble.dispose();
    final slowBle =
        _HookedUnsubscribeBle(
            devices: const [
              FakeDevice(
                id: _bleDeviceId,
                name: 'WMR Bridge',
                services: fakeBridgeDeviceServices,
              ),
            ],
            onUnsubscribe: (deviceId, serviceUuid, characteristicUuid) async {
              await Future<void>.delayed(const Duration(milliseconds: 180));
            },
          )
          ..onRead = (deviceId, characteristicUuid) {
            if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
              return _endpointDocument();
            }
            throw StateError('unexpected read $characteristicUuid');
          };
    ble = slowBle;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    final batchedSub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen((_) {});
    final decodedSub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeDecodedCharUuid)
        .listen((_) {});
    final streamSub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid)
        .listen((_) {});
    addTearDown(batchedSub.cancel);
    addTearDown(decodedSub.cancel);
    addTearDown(streamSub.cancel);

    tcp.failConnect = false;
    tcp.endpoints.remove(_tcpDeviceId);
    final sw = Stopwatch()..start();
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'upgrade did not land on TCP',
    );
    sw.stop();

    // TCP activation must not wait on the 180 ms BLE GATT unsubscribe writes.
    expect(sw.elapsedMilliseconds, lessThan(150));
    expect(ble.isSubscribed(_bleDeviceId, wmrBridgeBatchedCharUuid), isFalse);
    expect(ble.isSubscribed(_bleDeviceId, wmrBridgeDecodedCharUuid), isFalse);
    expect(ble.isSubscribed(_bleDeviceId, wmrBridgeStreamCharUuid), isFalse);

    tcp.emit(
      _lanDeviceId,
      wmrBridgeBatchedCharUuid,
      Uint8List.fromList([7, 8]),
    );
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['first_tcp_record_us'] !=
          null,
      reason: 'first_tcp_record_us was not stamped',
    );
    final timeline = transport.linkTimelineFor(_tcpDeviceId)!;
    expect(timeline['upgrade_outcome'], 'landed');

    // Once the slow BLE GATT writes complete (3 * 180 ms > 250 ms default
    // bleUnsubscribeTimeout), all non-echo CCCDs are off without truncation.
    await _waitFor(
      () =>
          ble.cccLog.contains('off $wmrBridgeBatchedCharUuid') &&
          ble.cccLog.contains('off $wmrBridgeDecodedCharUuid') &&
          ble.cccLog.contains('off $wmrBridgeStreamCharUuid'),
      reason: 'slow BLE unsubscribe did not turn off non-echo CCCDs',
    );
  });

  test('T2: never-completing ble.unsubscribe does not stall TCP upgrade or retries', () async {
    tcp.failConnect = true;
    ble.dispose();
    final hungBle =
        _HookedUnsubscribeBle(
            devices: const [
              FakeDevice(
                id: _bleDeviceId,
                name: 'WMR Bridge',
                services: fakeBridgeDeviceServices,
              ),
            ],
            onUnsubscribe: (deviceId, serviceUuid, characteristicUuid) =>
                Completer<void>().future,
          )
          ..onRead = (deviceId, characteristicUuid) {
            if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
              return _endpointDocument();
            }
            throw StateError('unexpected read $characteristicUuid');
          };
    ble = hungBle;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    final received = <BleNotification>[];
    final sub = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);

    tcp.failConnect = false;
    tcp.endpoints.remove(_tcpDeviceId);
    final sw = Stopwatch()..start();
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'upgrade did not land on TCP under hung ble.unsubscribe',
    );
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(500));
    final connectsAtLand = tcp.connectCalls
        .where((id) => id == _lanDeviceId)
        .length;

    tcp.emit(
      _lanDeviceId,
      wmrBridgeBatchedCharUuid,
      Uint8List.fromList([9, 10]),
    );
    await _waitFor(
      () =>
          transport.linkTimelineFor(_tcpDeviceId)!['first_tcp_record_us'] !=
          null,
      reason: 'first_tcp_record_us was not stamped',
    );
    expect(received, hasLength(1));
    expect(
      transport.linkTimelineFor(_tcpDeviceId)!['upgrade_outcome'],
      'landed',
    );

    await _settle(50);
    expect(
      tcp.connectCalls.where((id) => id == _lanDeviceId).length,
      connectsAtLand,
      reason: 'upgrade retries continued after landing',
    );
  });

  test('T3: synchronous or asynchronous throw from ble.unsubscribe still lands TCP upgrade', () async {
    for (final syncThrow in [true, false]) {
      await tcp.dispose();
      tcp = _FakeTcp()
        ..registerEndpoint(
          WmrWsEndpoint(
            host: '127.0.0.1',
            port: 8765,
            deviceId: _tcpDeviceId,
            bridgeId: _bridgeId,
          ),
        )
        ..scanResults.add(tcpScanResult())
        ..failConnect = true;
      ble.dispose();
      ble =
          _HookedUnsubscribeBle(
              devices: const [
                FakeDevice(
                  id: _bleDeviceId,
                  name: 'WMR Bridge',
                  services: fakeBridgeDeviceServices,
                ),
              ],
              onUnsubscribe: (deviceId, serviceUuid, characteristicUuid) {
                if (syncThrow) throw StateError('sync unsubscribe failure');
                return Future<void>.error(
                  StateError('async unsubscribe failure'),
                );
              },
            )
            ..onRead = (deviceId, characteristicUuid) {
              if (characteristicUuid.toLowerCase() ==
                  wmrBridgeVersionCharUuid) {
                return _endpointDocument();
              }
              throw StateError('unexpected read $characteristicUuid');
            };

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 10),
      );

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

      final received = <BleNotification>[];
      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen(received.add);

      tcp.failConnect = false;
      tcp.endpoints.remove(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
        reason: 'upgrade did not land when syncThrow=$syncThrow',
      );

      tcp.emit(
        _lanDeviceId,
        wmrBridgeBatchedCharUuid,
        Uint8List.fromList([11, 12]),
      );
      await _waitFor(
        () =>
            transport.linkTimelineFor(_tcpDeviceId)!['first_tcp_record_us'] !=
            null,
        reason: 'first_tcp_record_us not stamped when syncThrow=$syncThrow',
      );
      expect(received, hasLength(1));
      expect(
        transport.linkTimelineFor(_tcpDeviceId)!['upgrade_outcome'],
        'landed',
      );

      await sub.cancel();
      await transport.dispose();
    }
  });

  test('T4a: TCP drop during _activateTcp under route.upgrading does not split episode with null outcome', () async {
    // Drop TCP mid-activation: once before route.active becomes TCP (during
    // BLE detach), and once after route.active becomes TCP (during TCP
    // subscribe while route.upgrading is still true).
    for (final dropDuringSubscribe in [false, true]) {
      await tcp.dispose();
      var dropArmed = false;
      late final _HookedTcp hookedTcp;
      hookedTcp =
          _HookedTcp(
              onSubscribe: (deviceId) {
                if (dropDuringSubscribe &&
                    dropArmed &&
                    deviceId == _lanDeviceId) {
                  dropArmed = false;
                  hookedTcp.failConnect = true;
                  hookedTcp.drop(_lanDeviceId);
                }
              },
            )
            ..registerEndpoint(
              WmrWsEndpoint(
                host: '127.0.0.1',
                port: 8765,
                deviceId: _tcpDeviceId,
                bridgeId: _bridgeId,
              ),
            )
            ..scanResults.add(tcpScanResult());
      tcp = hookedTcp;

      ble.dispose();
      var bleDetachDropArmed = !dropDuringSubscribe;
      ble =
          _HookedCancelBle(
              devices: const [
                FakeDevice(
                  id: _bleDeviceId,
                  name: 'WMR Bridge',
                  services: fakeBridgeDeviceServices,
                ),
              ],
              onCancel: () async {
                await Future<void>.delayed(const Duration(milliseconds: 10));
                if (!dropDuringSubscribe && bleDetachDropArmed) {
                  bleDetachDropArmed = false;
                  hookedTcp.failConnect = true;
                  hookedTcp.drop(_lanDeviceId);
                }
              },
            )
            ..onRead = (deviceId, characteristicUuid) {
              if (characteristicUuid.toLowerCase() ==
                  wmrBridgeVersionCharUuid) {
                return _endpointDocument();
              }
              throw StateError('unexpected read $characteristicUuid');
            };

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(milliseconds: 200),
        upgradeRetryDelay: Duration.zero,
      );

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);

      final sub = transport
          .subscribe(
            _tcpDeviceId,
            wmrBridgeServiceUuid,
            wmrBridgeBatchedCharUuid,
          )
          .listen((_) {});

      // Episode 1: initial TCP stalls and fails over to BLE while TCP is down.
      expect(tcp.emit(_tcpDeviceId, wmrBridgeBatchedCharUuid, [1]), isTrue);
      await _settle();
      tcp.failConnect = true;
      tcp.drop(_tcpDeviceId);
      await _waitFor(
        () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
        reason: 'initial failover to BLE did not land',
      );
      final failoverEndOne =
          transport.linkTimelineFor(_tcpDeviceId)!['failover_end_us']! as int;

      // Now arm the mid-activation TCP drop and let the upgrade dial succeed.
      // After the drop, keep TCP down so the recovery back to BLE settles.
      dropArmed = true;
      bleDetachDropArmed = !dropDuringSubscribe;
      tcp.failConnect = false;
      tcp.endpoints.remove(_tcpDeviceId);
      await _waitFor(
        () =>
            transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble &&
            (transport.linkTimelineFor(_tcpDeviceId)!['failover_end_us']!
                    as int) >
                failoverEndOne,
        reason: 'mid-activation TCP drop did not recover back to BLE',
      );

      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      final episodes = marks['episodes']! as List<Object?>;
      expect(episodes, hasLength(1));
      final episodeOne = episodes.single as Map<String, Object?>;
      expect(
        episodeOne['upgrade_outcome'],
        'landed',
        reason: 'episode 1 must not be archived with upgrade_outcome: null',
      );
      expect(
        marks['upgrade_outcome'],
        isNot('landed'),
        reason: 'landed must not leak into the successor episode',
      );

      await sub.cancel();
      await transport.dispose();
    }
  });

  test('T4b: TCP drop + _fallbackToBle fences stale ble.unsubscribe and late BLE records', () async {
    tcp.failConnect = true;
    ble.dispose();
    final unsubGate = Completer<void>();
    var gateFirstUnsub = true;
    final lateBle =
        _LateRecordAndGatedUnsubBle(
            devices: const [
              FakeDevice(
                id: _bleDeviceId,
                name: 'WMR Bridge',
                services: fakeBridgeDeviceServices,
              ),
            ],
            onUnsubscribe: (deviceId, serviceUuid, characteristicUuid) {
              if (gateFirstUnsub) {
                gateFirstUnsub = false;
                return unsubGate.future;
              }
              return Future<void>.value();
            },
          )
          ..onRead = (deviceId, characteristicUuid) {
            if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
              return _endpointDocument();
            }
            throw StateError('unexpected read $characteristicUuid');
          };
    ble = lateBle;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    final batchedReceived = <BleNotification>[];
    final streamReceived = <BleNotification>[];
    final subBatched = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(batchedReceived.add);
    final subStream = transport
        .subscribe(_tcpDeviceId, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid)
        .listen(streamReceived.add);
    addTearDown(subBatched.cancel);
    addTearDown(subStream.cancel);

    // Upgrade to TCP while the first ble.unsubscribe is still pending.
    tcp.failConnect = false;
    tcp.endpoints.remove(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'upgrade did not land on TCP',
    );
    expect(lateBle.cccLog.where((e) => e.startsWith('off ')), hasLength(1));

    // Late BLE record on the superseded BLE subscription while TCP is active
    // must neither stamp first_ble_record_us nor emit to the subscriber.
    lateBle.emitOnSuperseded(wmrBridgeBatchedCharUuid, [99]);
    await _settle();
    expect(batchedReceived, isEmpty);
    expect(
      transport.linkTimelineFor(_tcpDeviceId)!['first_ble_record_us'],
      isNull,
    );

    // TCP drops and _fallbackToBle re-activates BLE while the earlier
    // ble.unsubscribe is still pending.
    tcp.failConnect = true;
    tcp.drop(_lanDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'fallback to BLE did not land',
    );

    // Unblock the pending earlier ble.unsubscribe: the stale teardown must
    // NOT fire ble.unsubscribe for the second characteristic.
    unsubGate.complete();
    await _settle(30);
    expect(
      lateBle.cccLog.where((e) => e.startsWith('off ')),
      hasLength(1),
      reason: 'stale teardown fired ble.unsubscribe after fallback to BLE',
    );

    // A late record on the superseded BLE subscription after fallback must be
    // dropped; only the newly re-attached BLE subscription delivers records.
    lateBle.emitOnSuperseded(wmrBridgeBatchedCharUuid, [88]);
    await _settle();
    expect(batchedReceived, isEmpty);

    expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [7]), isTrue);
    expect(ble.emit(_bleDeviceId, wmrBridgeStreamCharUuid, [8]), isTrue);
    await _waitFor(
      () => batchedReceived.length == 1 && streamReceived.length == 1,
      reason: 're-attached BLE subscriptions did not deliver records',
    );
    expect(batchedReceived.single.value, orderedEquals([7]));
    expect(streamReceived.single.value, orderedEquals([8]));
  });

  test('T6: disconnect, suspendBleStreams, and dispose are bounded under hung ble.unsubscribe with zero leaked timers', () async {
    Future<void> verifyBoundedWithZeroTimers(
      String label,
      Future<void> Function(CompositeBleTransport transport) action,
    ) async {
      final activeTimers = <_TrackedTimer>[];
      await runZoned(
        () async {
          final localTcp = _FakeTcp()
            ..registerEndpoint(
              WmrWsEndpoint(
                host: '127.0.0.1',
                port: 8765,
                deviceId: _tcpDeviceId,
                bridgeId: _bridgeId,
              ),
            )
            ..scanResults.add(tcpScanResult())
            ..failConnect = true;
          final localBle =
              _HookedUnsubscribeBle(
                  devices: const [
                    FakeDevice(
                      id: _bleDeviceId,
                      name: 'WMR Bridge',
                      services: fakeBridgeDeviceServices,
                    ),
                  ],
                  onUnsubscribe: (deviceId, serviceUuid, characteristicUuid) =>
                      Completer<void>().future,
                )
                ..onRead = (deviceId, characteristicUuid) {
                  if (characteristicUuid.toLowerCase() ==
                      wmrBridgeVersionCharUuid) {
                    return _versionString();
                  }
                  throw StateError('unexpected read $characteristicUuid');
                };

          final transport = CompositeBleTransport(
            tcp: localTcp,
            ble: localBle,
            upgradeInterval: const Duration(hours: 1),
          );

          await transport.scan().toList();
          await transport.connect(_tcpDeviceId);
          final sub = transport
              .subscribe(
                _tcpDeviceId,
                wmrBridgeServiceUuid,
                wmrBridgeBatchedCharUuid,
              )
              .listen((_) {});

          final sw = Stopwatch()..start();
          await action(transport);
          sw.stop();
          expect(
            sw.elapsedMilliseconds,
            lessThan(1000),
            reason: '$label took too long under hung ble.unsubscribe',
          );

          await sub.cancel();
          await transport.dispose();
          await localTcp.dispose();
          localBle.dispose();
          await _settle(20);

          expect(
            activeTimers.where((t) => t.isActive),
            isEmpty,
            reason: '$label leaked active timers',
          );
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, f) {
            late final _TrackedTimer tracked;
            final inner = parent.createTimer(zone, duration, () {
              tracked.markDone();
              f();
            });
            tracked = _TrackedTimer(inner);
            activeTimers.add(tracked);
            return tracked;
          },
          createPeriodicTimer: (self, parent, zone, period, f) {
            late final _TrackedTimer tracked;
            final inner = parent.createPeriodicTimer(zone, period, (t) {
              f(t);
            });
            tracked = _TrackedTimer(inner);
            activeTimers.add(tracked);
            return tracked;
          },
        ),
      );
    }

    await verifyBoundedWithZeroTimers(
      'disconnect',
      (t) => t.disconnect(_tcpDeviceId),
    );
    await verifyBoundedWithZeroTimers(
      'suspendBleStreams',
      (t) => t.suspendBleStreams(_tcpDeviceId),
    );
    await verifyBoundedWithZeroTimers('dispose', (t) => t.dispose());
  });

  test(
    'connect() prefers bleError over tcpError when BLE fallback fails',
    () async {
      tcp.failConnect = true;
      ble.dispose();
      final refusing = _RecordingBle(
        devices: const [
          FakeDevice(
            id: _bleDeviceId,
            name: 'WMR Bridge',
            services: fakeBridgeDeviceServices,
          ),
        ],
      )..refusedConnects.add(_bleDeviceId);
      refusing.onRead = (deviceId, characteristicUuid) {
        if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
          return _versionString();
        }
        throw StateError('unexpected read $characteristicUuid');
      };
      ble = refusing;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
      );
      addTearDown(transport.dispose);
      await transport.scan().toList();

      await expectLater(
        transport.connect(_tcpDeviceId),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'ble connect refused',
          ),
        ),
      );
    },
  );

  test('_bleCandidatesFor falls through to fresh _scanHits when cached bleDeviceId fails', () async {
    const staleBleId = 'ble-stale';
    const freshBleId = 'ble-fresh';
    tcp.failConnect = true;
    ble.dispose();
    final multi = _RecordingBle(
      devices: const [
        FakeDevice(
          id: staleBleId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
        FakeDevice(
          id: freshBleId,
          name: 'WMR Bridge',
          services: fakeBridgeDeviceServices,
        ),
      ],
    );
    multi.onRead = (deviceId, characteristicUuid) {
      if (characteristicUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
        return _endpointDocument();
      }
      throw StateError('unexpected read $characteristicUuid');
    };
    ble = multi;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: const Duration(milliseconds: 20),
    );
    addTearDown(transport.dispose);

    // Learn staleBleId first, then let it upgrade to TCP so route.bleDeviceId
    // stays cached as staleBleId.
    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    tcp.failConnect = false;
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
    );

    // Now staleBleId drops and refuses connect while TCP drops: failover must
    // try staleBleId first and then fall through to freshBleId from _scanHits.
    multi.refusedConnects.add(staleBleId);
    await multi.disconnect(staleBleId);
    tcp.failConnect = true;
    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
    );
    expect(transport.bleDeviceIdFor(_tcpDeviceId), freshBleId);
  });

  test('fallbackReadinessFor classifies WMB1 serviceData before and after hello, FF16-verified, and unverified hits', () async {
    await tcp.dispose();
    const manualId = '127.0.0.1:8765';
    const bridgeId = 'abcdef1234567890';
    tcp = _FakeTcp()
      ..registerEndpoint(
        WmrWsEndpoint(host: '127.0.0.1', port: 8765, deviceId: manualId),
      );
    tcp.hellos[manualId] = WmrWsHello(
      protocol: 1,
      transport: 'tcp',
      device: manualId,
      version: '0.2.4',
      hostname: 'wmrpi',
      authRequired: false,
      streams: const {'raw', 'decoded', 'batched'},
      recordSize: 56,
      batchMax: 9,
      fragmentCapacity: 46,
    );
    ble.dispose();
    final unverifiedBle = _ServiceDataBle(
      results: [
        const BleScanResult(deviceId: 'unverified-1', name: 'wmrpi', rssi: -50),
        BleScanResult(
          deviceId: 'verified-1',
          name: 'WMR Bridge',
          rssi: -45,
          serviceUuids: const [wmrBridgeServiceUuid],
          serviceData: {
            wmrBridgeServiceUuid: Uint8List.fromList(
              utf8.encode('WMB1abcdef12'),
            ),
          },
        ),
      ],
    );
    ble = unverifiedBle;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: Duration.zero,
    );
    addTearDown(transport.dispose);

    // Before hello supplies bridgeId, both hits are unverified.
    final sub = transport.scan().listen((_) {});
    addTearDown(sub.cancel);
    await _settle();

    await transport.connect(manualId);
    var readiness = transport.fallbackReadinessFor(manualId);
    expect(readiness.hasVerified, isFalse);
    expect(readiness.unverifiedCount, 2);

    // Simulate hello later supplying bridgeId -> re-evaluates WMB1 hit to verified.
    await transport.disconnect(manualId);
    tcp.hellos[manualId] = WmrWsHello(
      protocol: 1,
      transport: 'tcp',
      device: manualId,
      version: '0.2.4',
      hostname: 'wmrpi',
      bridgeId: bridgeId,
      authRequired: false,
      streams: const {'raw', 'decoded', 'batched'},
      recordSize: 56,
      batchMax: 9,
      fragmentCapacity: 46,
    );
    await transport.connect(manualId);
    readiness = transport.fallbackReadinessFor(manualId);
    expect(readiness.hasVerified, isTrue);
    expect(readiness.verifiedCount, 1);
    expect(readiness.unverifiedCount, 1);
  });

  test('requireIdentity rejects a single unverified candidate with null, non-JSON, or mismatched FF16', () async {
    for (final payload in <Uint8List?>[
      null,
      _versionString('0.3.0-pi'),
      _endpointDocument(bridgeId: 'other-bridge'),
    ]) {
      await tcp.dispose();
      tcp = _FakeTcp()
        ..registerEndpoint(
          WmrWsEndpoint(
            host: '127.0.0.1',
            port: 8765,
            deviceId: _tcpDeviceId,
            bridgeId: _bridgeId,
          ),
        )
        ..scanResults.add(tcpScanResult());
      ble.dispose();
      ble =
          FakeTransport(
              devices: const [
                FakeDevice(
                  id: _bleDeviceId,
                  name: 'wmrpi',
                  services: fakeBridgeDeviceServices,
                ),
              ],
            )
            ..onRead = (_, charUuid) {
              if (charUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
                if (payload == null) throw StateError('no FF16');
                return payload;
              }
              throw StateError('unexpected read $charUuid');
            };

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
        bleScanWait: Duration.zero,
      );
      addTearDown(transport.dispose);

      await transport.scan().toList();
      await transport.connect(_tcpDeviceId);
      expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
      await _settle();

      tcp.failConnect = true;
      tcp.drop(_tcpDeviceId);
      await _waitFor(() => transport.activeLegFor(_tcpDeviceId) == null);
      final marks = transport.linkTimelineFor(_tcpDeviceId)!;
      expect(marks['failover_outcome'], 'lost');
      expect(marks['failover_reason'], 'connect_threw');
      expect(marks['failover_candidate_count'], 1);
    }
  });

  test('_fallbackToBle starts a bounded scan when !_scanning and zero candidates exist, and lands on matching FF16', () async {
    await tcp.dispose();
    tcp = _FakeTcp()
      ..registerEndpoint(
        WmrWsEndpoint(
          host: '127.0.0.1',
          port: 8765,
          deviceId: _tcpDeviceId,
          bridgeId: _bridgeId,
        ),
      );
    ble.dispose();
    final lateBle =
        _ServiceDataBle(
            results: [
              const BleScanResult(
                deviceId: _bleDeviceId,
                name: 'wmrpi',
                rssi: -45,
              ),
            ],
            emitDelay: const Duration(milliseconds: 20),
          )
          ..onRead = (_, charUuid) {
            if (charUuid.toLowerCase() == wmrBridgeVersionCharUuid) {
              return _endpointDocument(bridgeId: _bridgeId);
            }
            throw StateError('unexpected read $charUuid');
          };
    ble = lateBle;

    final transport = CompositeBleTransport(
      tcp: tcp,
      ble: ble,
      upgradeInterval: Duration.zero,
      bleScanWait: const Duration(milliseconds: 500),
    );
    addTearDown(transport.dispose);

    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
    await _settle();

    tcp.failConnect = true;
    tcp.drop(_tcpDeviceId);
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.ble,
      reason: 'bounded failover scan did not land BLE',
    );
    expect(transport.bleDeviceIdFor(_tcpDeviceId), _bleDeviceId);
    expect(
      transport.linkTimelineFor(_tcpDeviceId)!['failover_outcome'],
      'landed',
    );
  });

  test(
    '_fallbackToBle bounded scan cancels cleanly on intentional disconnect',
    () async {
      await tcp.dispose();
      tcp = _FakeTcp()
        ..registerEndpoint(
          WmrWsEndpoint(
            host: '127.0.0.1',
            port: 8765,
            deviceId: _tcpDeviceId,
            bridgeId: _bridgeId,
          ),
        );
      ble.dispose();
      ble = _ServiceDataBle(results: const []);

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: Duration.zero,
        bleScanWait: const Duration(seconds: 5),
      );
      addTearDown(transport.dispose);

      await transport.connect(_tcpDeviceId);
      tcp.failConnect = true;
      tcp.drop(_tcpDeviceId);
      await _settle(30);

      final sw = Stopwatch()..start();
      await transport.disconnect(_tcpDeviceId);
      expect(sw.elapsedMilliseconds, lessThan(500));
    },
  );
}

class _TrackedTimer implements Timer {
  _TrackedTimer(this._inner);

  final Timer _inner;
  bool _done = false;

  void markDone() => _done = true;

  @override
  void cancel() {
    _done = true;
    _inner.cancel();
  }

  @override
  bool get isActive => !_done && _inner.isActive;

  @override
  int get tick => _inner.tick;
}

class _HookedUnsubscribeBle extends FakeTransport {
  _HookedUnsubscribeBle({required super.devices, required this.onUnsubscribe});

  final Future<void> Function(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  )
  onUnsubscribe;

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    cccLog.add('off ${characteristicUuid.toLowerCase()}');
    await onUnsubscribe(deviceId, serviceUuid, characteristicUuid);
  }
}

class _HookedTcp extends _FakeTcp {
  _HookedTcp({required this.onSubscribe});

  final void Function(String deviceId) onSubscribe;

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    onSubscribe(deviceId);
    return super.subscribe(deviceId, serviceUuid, characteristicUuid);
  }
}

class _HookedCancelBle extends FakeTransport {
  _HookedCancelBle({required super.devices, required this.onCancel});

  final Future<void> Function() onCancel;

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final upstream = super.subscribe(deviceId, serviceUuid, characteristicUuid);
    late final StreamController<BleNotification> controller;
    StreamSubscription<BleNotification>? sub;
    controller = StreamController<BleNotification>(
      onListen: () {
        sub = upstream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () async {
        await onCancel();
        await sub?.cancel();
      },
    );
    return controller.stream;
  }
}

class _LateRecordAndGatedUnsubBle extends FakeTransport {
  _LateRecordAndGatedUnsubBle({
    required super.devices,
    required this.onUnsubscribe,
  });

  final Future<void> Function(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  )
  onUnsubscribe;

  final Map<String, List<StreamController<BleNotification>>> _controllers = {};

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final key = characteristicUuid.toLowerCase();
    final upstream = super.subscribe(deviceId, serviceUuid, characteristicUuid);
    // Keep a controller whose onCancel does not stop forwarding from the
    // superseded listener until we test late-record delivery, simulating a
    // deferred/async platform cancel.
    late final StreamController<BleNotification> controller;
    StreamSubscription<BleNotification>? sub;
    controller = StreamController<BleNotification>(
      onListen: () {
        sub = upstream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await sub?.cancel();
      },
    );
    _controllers.putIfAbsent(key, () => []).add(controller);
    return controller.stream;
  }

  void emitOnSuperseded(String characteristicUuid, List<int> bytes) {
    final list = _controllers[characteristicUuid.toLowerCase()];
    if (list == null || list.isEmpty) return;
    final first = list.first;
    if (!first.isClosed && first.hasListener) {
      first.add(
        BleNotification(
          value: Uint8List.fromList(bytes),
          receivedAtUs: clock.nowUs,
        ),
      );
    }
  }

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    cccLog.add('off ${characteristicUuid.toLowerCase()}');
    await onUnsubscribe(deviceId, serviceUuid, characteristicUuid);
  }
}

class _ServiceDataBle extends FakeTransport {
  _ServiceDataBle({required this.results, this.emitDelay = Duration.zero})
    : super(
        devices: [
          for (final r in results)
            FakeDevice(
              id: r.deviceId,
              name: r.name ?? 'WMR Bridge',
              services: fakeBridgeDeviceServices,
            ),
        ],
      );

  final List<BleScanResult> results;
  final Duration emitDelay;

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) {
    late final StreamController<BleScanResult> ctl;
    Timer? timer;
    ctl = StreamController<BleScanResult>(
      onListen: () {
        void emit() {
          for (final r in results) {
            if (!ctl.isClosed) ctl.add(r);
          }
        }

        if (emitDelay > Duration.zero) {
          timer = Timer(emitDelay, emit);
        } else {
          emit();
        }
      },
      onCancel: () {
        timer?.cancel();
      },
    );
    return ctl.stream;
  }
}
