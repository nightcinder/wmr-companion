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
      'authRequired': false,
    }),
  ),
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
  bool _disposed = false;

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      Stream.fromIterable(scanResults);

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    connectCalls.add(deviceId);
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
      expect(received.last.value, [8]);
      expect(ble.emit(_bleDeviceId, wmrBridgeBatchedCharUuid, [9]), isFalse);
      expect(states, isNot(contains(BleConnectionState.disconnected)));

      // Both transports now name the same bridge_id, so a later scan keeps one
      // entry for it.
      final deduped = await transport.scan().toList();
      expect(deduped, hasLength(1));
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
}
