import 'dart:async';
import 'dart:typed_data';

import 'ble_transport.dart';

/// A device the [FakeTransport] pretends to see.
class FakeDevice {
  const FakeDevice({
    required this.id,
    this.name,
    this.rssi = -50,
    this.mtu = 247,
    this.services = const [],
  });

  final String id;
  final String? name;
  final int rssi;
  final int mtu;
  final List<BleServiceInfo> services;
}

/// A write the app sent to the [FakeTransport].
class FakeWrite {
  const FakeWrite({
    required this.deviceId,
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.value,
    required this.withoutResponse,
  });

  final String deviceId;
  final String serviceUuid;
  final String characteristicUuid;
  final Uint8List value;
  final bool withoutResponse;
}

/// In-memory [BleTransport] for tests and UI work without hardware.
///
/// It knows nothing about the packet format: callers push raw bytes with
/// [emit] and react to writes through [onWrite].
class FakeTransport implements BleTransport {
  FakeTransport({List<FakeDevice> devices = const [], MonotonicClock? clock})
    : clock = clock ?? MonotonicClock(),
      _devices = {for (final d in devices) d.id: d};

  @override
  final MonotonicClock clock;

  final Map<String, FakeDevice> _devices;
  final Map<String, BleConnectionState> _states = {};
  final Map<String, StreamController<BleConnectionState>> _stateControllers =
      {};
  final Map<String, StreamController<BleNotification>> _subscriptions = {};

  /// Every write received, oldest first.
  final List<FakeWrite> writes = [];

  /// CCC changes in order: `on <uuid>` per [subscribe], `off <uuid>` per
  /// [unsubscribe].
  final List<String> cccLog = [];

  /// Called for every write, after it is recorded in [writes].
  FutureOr<void> Function(FakeWrite write)? onWrite;
  final List<FutureOr<void> Function(FakeWrite write)> _writeHandlers = [];

  /// Every read received, oldest first, as `<deviceId> <uuid>`.
  final List<String> reads = [];

  /// Supplies the value of a read. Without it a read throws [StateError].
  FutureOr<Uint8List> Function(String deviceId, String characteristicUuid)?
  onRead;
  final List<
    FutureOr<Uint8List?> Function(String deviceId, String characteristicUuid)
  >
  _readHandlers = [];

  void addDevice(FakeDevice device) {
    _devices[device.id] = device;
  }

  void addWriteHandler(FutureOr<void> Function(FakeWrite write) handler) {
    _writeHandlers.add(handler);
  }

  void addReadHandler(
    FutureOr<Uint8List?> Function(String deviceId, String characteristicUuid)
    handler,
  ) {
    _readHandlers.add(handler);
  }

  bool _scanning = false;
  bool get isScanning => _scanning;

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) {
    _scanning = true;
    final wanted = withServices.map(_norm).toSet();
    final results = _devices.values
        .where((d) {
          if (wanted.isEmpty) return true;
          return d.services.any((s) => wanted.contains(_norm(s.uuid)));
        })
        .map(
          (d) => BleScanResult(
            deviceId: d.id,
            name: d.name,
            rssi: d.rssi,
            serviceUuids: [for (final s in d.services) s.uuid],
          ),
        );
    return Stream.fromIterable(results);
  }

  @override
  Future<void> stopScan() async => _scanning = false;

  @override
  Future<void> connect(String deviceId) async {
    _device(deviceId);
    _setState(deviceId, BleConnectionState.connected);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    final prefix = '$deviceId|';
    final keys = _subscriptions.keys.where((k) => k.startsWith(prefix));
    for (final key in keys.toList()) {
      await _subscriptions.remove(key)!.close();
    }
    _setState(deviceId, BleConnectionState.disconnected);
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    yield _states[deviceId] ?? BleConnectionState.disconnected;
    yield* _stateController(deviceId).stream;
  }

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) async {
    _requireConnected(deviceId);
    return _device(deviceId).services;
  }

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    _requireConnected(deviceId);
    cccLog.add('on ${_norm(characteristicUuid)}');
    return _subscriptions
        .putIfAbsent(
          _key(deviceId, characteristicUuid),
          StreamController<BleNotification>.broadcast,
        )
        .stream;
  }

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    _requireConnected(deviceId);
    cccLog.add('off ${_norm(characteristicUuid)}');
    await _subscriptions.remove(_key(deviceId, characteristicUuid))?.close();
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    _requireConnected(deviceId);
    reads.add('$deviceId ${_norm(characteristicUuid)}');
    final handler = onRead;
    if (handler != null) return handler(deviceId, characteristicUuid);
    for (final h in _readHandlers) {
      final res = await h(deviceId, characteristicUuid);
      if (res != null) return res;
    }
    throw StateError('FakeTransport: no onRead handler');
  }

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    _requireConnected(deviceId);
    final write = FakeWrite(
      deviceId: deviceId,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
      value: Uint8List.fromList(value),
      withoutResponse: withoutResponse,
    );
    writes.add(write);
    await onWrite?.call(write);
    for (final h in _writeHandlers) {
      await h(write);
    }
  }

  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) async {
    _requireConnected(deviceId);
    final d = _device(deviceId);
    return BleConnectionInfo(mtu: d.mtu, rssi: d.rssi);
  }

  /// True while someone listens to [characteristicUuid] of [deviceId].
  bool isSubscribed(String deviceId, String characteristicUuid) =>
      _subscriptions[_key(deviceId, characteristicUuid)]?.hasListener ?? false;

  /// Delivers [value] as a notification on [characteristicUuid], stamped with
  /// [clock]. Returns false if nobody is subscribed.
  bool emit(String deviceId, String characteristicUuid, List<int> value) {
    final controller = _subscriptions[_key(deviceId, characteristicUuid)];
    if (controller == null || !controller.hasListener) return false;
    controller.add(
      BleNotification(
        value: Uint8List.fromList(value),
        receivedAtUs: clock.nowUs,
      ),
    );
    return true;
  }

  @override
  Future<void> dispose() async {
    for (final c in _subscriptions.values) {
      await c.close();
    }
    for (final c in _stateControllers.values) {
      await c.close();
    }
    _subscriptions.clear();
    _stateControllers.clear();
  }

  FakeDevice _device(String deviceId) {
    final d = _devices[deviceId];
    if (d == null) throw StateError('Unknown device $deviceId');
    return d;
  }

  void _requireConnected(String deviceId) {
    if (_states[deviceId] != BleConnectionState.connected) {
      throw StateError('Device $deviceId is not connected');
    }
  }

  void _setState(String deviceId, BleConnectionState state) {
    _states[deviceId] = state;
    _stateController(deviceId).add(state);
  }

  StreamController<BleConnectionState> _stateController(String deviceId) =>
      _stateControllers.putIfAbsent(
        deviceId,
        StreamController<BleConnectionState>.broadcast,
      );

  static String _key(String deviceId, String characteristicUuid) =>
      '$deviceId|${_norm(characteristicUuid)}';

  static String _norm(String uuid) => uuid.toLowerCase();
}
