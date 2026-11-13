import 'dart:async';
import 'dart:convert';
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
  bool failConnect = false;

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
    _setState(deviceId, BleConnectionState.disconnected);
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    yield states[deviceId] ?? BleConnectionState.disconnected;
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
  ) => _stream(deviceId, characteristicUuid).stream;

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

  bool emit(String deviceId, String characteristicUuid, List<int> value) {
    final controller = streams[_key(deviceId, characteristicUuid)];
    if (controller == null || !controller.hasListener) return false;
    controller.add(
      BleNotification(
        value: Uint8List.fromList(value),
        receivedAtUs: clock.nowUs,
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
class _HeldDialTcp extends _FakeTcp {
  final Completer<void> release = Completer<void>();
  final List<String> disconnectCalls = [];
  Future<void>? _pending;
  int dialAttempts = 0;

  @override
  Future<void> connect(String deviceId) {
    dialAttempts++;
    final pending = _pending;
    if (pending != null) return pending;
    final dial = _dial(deviceId);
    _pending = dial;
    return dial;
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnectCalls.add(deviceId);
    return super.disconnect(deviceId);
  }

  Future<void> _dial(String deviceId) async {
    await release.future;
    await super.connect(deviceId);
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
    ble = newBle();
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

  test(
    're-promotes a configured TCP endpoint when FF16 is a version string',
    () async {
      tcp.failConnect = true;
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
                return _versionString();
              }
              throw StateError('unexpected read $characteristicUuid');
            };
      ble = gated;

      final transport = CompositeBleTransport(
        tcp: tcp,
        ble: ble,
        upgradeInterval: const Duration(hours: 1),
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

  test('a slow dial adopted by a later upgrade probe stays connected', () async {
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
      tcpProbeBudget: const Duration(milliseconds: 60),
      upgradeInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.scan().toList();
    await transport.connect(_tcpDeviceId);
    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.ble);

    // The upgrade timer joins the dial the first attempt abandoned. Landing it
    // now must upgrade the route, not be closed as a stale socket.
    await _waitFor(
      () => held.dialAttempts >= 2,
      reason: 'the upgrade probe never joined the held dial',
    );
    held.release.complete();
    await _waitFor(
      () => transport.activeLegFor(_tcpDeviceId) == CompositeLeg.tcp,
      reason: 'the adopted dial did not upgrade the route',
    );
    await _settle(50);

    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
    expect(
      held.disconnectCalls,
      isEmpty,
      reason: 'the adopted dial was closed as a stale socket',
    );
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

    // The upgrade probe joins the held dial. Then the BLE drop starts a
    // recovery that joins the same dial, so both are still in flight when it
    // lands. The recovery adopts the socket; the probe must not close it.
    await _waitFor(
      () => held.dialAttempts >= 2,
      reason: 'the upgrade probe never joined the held dial',
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
      reason: 'the recovery did not adopt the held dial',
    );
    await _settle(50);

    expect(transport.activeLegFor(_tcpDeviceId), CompositeLeg.tcp);
    expect(
      held.disconnectCalls,
      isEmpty,
      reason: 'the probe closed the socket that the recovery adopted',
    );
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
            'tcp down',
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
    },
  );

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
}
