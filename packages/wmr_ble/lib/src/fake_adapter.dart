import 'dart:async';
import 'dart:typed_data';

import 'ble_adapter.dart';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';

/// Scriptable [BleAdapter] that records every call in order.
class FakeBleAdapter implements BleAdapter {
  final List<String> calls = [];

  bool permissionsGranted = true;
  bool grantOnRequest = true;
  BleAvailability availabilityState = BleAvailability.poweredOn;
  bool supportsPriority = true;
  int negotiatedMtu = 185;
  List<BleServiceInfo> services = fakeBridgeDevice.services;
  Object? connectError;

  /// Upcoming [connect] calls that fail with [connectError] (or a generic
  /// error when that is null). Lets a test make just the first automatic
  /// re-dial fail and check that the retry loop dials again.
  int connectFailureCount = 0;

  /// When set, [availability] waits for this completer before answering.
  Completer<void>? availabilityGate;

  /// When set, [requestMtu] waits for this completer before answering.
  Completer<void>? mtuGate;

  /// Object? set to make [requestMtu] throw.
  Object? mtuError;

  // Sync, like a platform callback: the transport must stamp in the callback.
  final _values = StreamController<(String?, String, Uint8List)>.broadcast(
    sync: true,
  );
  final _links = StreamController<AdapterConnectionEvent>.broadcast();
  final _scan = StreamController<BleScanResult>.broadcast();
  final _params = StreamController<AdapterConnectionParams>.broadcast();

  void emitNotification(
    String characteristic,
    List<int> value, {
    String? deviceId,
  }) => _values.add((deviceId, characteristic, Uint8List.fromList(value)));

  void emitScanResult(BleScanResult r) => _scan.add(r);

  void emitParams(String deviceId, int intervalUs) => _params.add(
    AdapterConnectionParams(deviceId: deviceId, intervalUs: intervalUs),
  );

  /// Simulates the bridge dropping the link. With [deviceId] only that
  /// bridge's session sees the event; without it every session does (the
  /// single-bridge tests).
  void dropLink({String? deviceId}) {
    calls.add('link-dropped');
    _enabled.clear();
    _links.add(
      AdapterConnectionEvent(
        connected: false,
        error: 'gone',
        deviceId: deviceId,
      ),
    );
  }

  @override
  bool get supportsConnectionPriority => supportsPriority;

  @override
  Future<bool> hasPermissions() async => permissionsGranted;

  @override
  Future<void> requestPermissions() async {
    calls.add('requestPermissions');
    if (!grantOnRequest) throw StateError('denied by user');
    permissionsGranted = true;
  }

  @override
  Future<BleAvailability> availability() async {
    await availabilityGate?.future;
    return availabilityState;
  }

  @override
  Stream<BleAvailability> get availabilityChanges => const Stream.empty();

  @override
  Stream<BleScanResult> get scanResults => _scan.stream;

  @override
  Future<void> startScan({
    required List<String> withServices,
    required List<String> withNamePrefixes,
  }) async => calls.add('startScan $withServices $withNamePrefixes');

  @override
  Future<void> stopScan() async => calls.add('stopScan');

  @override
  Future<void> connect(String deviceId) async {
    calls.add('connect');
    _enabled.clear();
    if (connectFailureCount > 0) {
      connectFailureCount--;
      throw connectError ?? StateError('connect failed');
    }
    if (connectError != null) throw connectError!;
    _links.add(const AdapterConnectionEvent(connected: true));
  }

  @override
  Future<void> disconnect(String deviceId) async {
    calls.add('disconnect');
    _enabled.clear();
  }

  @override
  Stream<AdapterConnectionEvent> connectionEvents(String deviceId) =>
      _links.stream.where((e) => e.deviceId == null || e.deviceId == deviceId);

  @override
  Future<int> requestMtu(String deviceId, int mtu) async {
    calls.add('requestMtu $mtu');
    await mtuGate?.future;
    if (mtuError != null) throw mtuError!;
    calls.add('mtuResult $negotiatedMtu');
    return negotiatedMtu;
  }

  @override
  Future<void> requestHighConnectionPriority(String deviceId) async =>
      calls.add('priorityHigh');

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) async {
    calls.add('discoverServices');
    return services;
  }

  /// Mirrors the firmware: while one of FF11/FF12/FF14 is enabled, enabling
  /// another fails with ATT error 0x80. State resets when the link drops or
  /// reconnects.
  bool bridgeExclusion = true;

  /// CCC writes in order, as `on <char>` / `off <char>`; `FAIL` entries mark
  /// refused writes.
  final List<String> ccc = [];
  final Set<String> _enabled = {};

  /// Characteristics whose enable or disable throws this.
  final Map<String, Object> enableErrors = {};
  final Map<String, Object> disableErrors = {};

  static String _short(String uuid) => uuid.substring(4, 8);
  static const _bridgeStreams = {'ff11', 'ff12', 'ff14'};

  @override
  Future<void> enableNotifications(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    calls.add('enableNotifications');
    final name = _short(characteristicUuid);
    final error = enableErrors[characteristicUuid];
    if (error != null) {
      ccc.add('FAIL on $name');
      throw error;
    }
    if (bridgeExclusion &&
        _enabled.any((c) => c != name && _bridgeStreams.contains(c)) &&
        _bridgeStreams.contains(name)) {
      ccc.add('FAIL on $name');
      throw const BleAdapterException('other stream active', attError: 0x80);
    }
    _enabled.add(name);
    ccc.add('on $name');
  }

  @override
  Future<void> disableNotifications(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    calls.add('disableNotifications');
    final error = disableErrors[characteristicUuid];
    if (error != null) {
      ccc.add('FAIL off ${_short(characteristicUuid)}');
      throw error;
    }
    _enabled.remove(_short(characteristicUuid));
    ccc.add('off ${_short(characteristicUuid)}');
  }

  @override
  Stream<Uint8List> notifications(String deviceId, String characteristicUuid) =>
      _values.stream
          .where(
            (e) =>
                (e.$1 == null || e.$1 == deviceId) &&
                e.$2 == characteristicUuid,
          )
          .map((e) => e.$3);

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    calls.add('read');
    return Uint8List(16);
  }

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    required bool withoutResponse,
  }) async => calls.add('write');

  @override
  Future<int> readRssi(String deviceId) async => -55;

  @override
  Stream<AdapterConnectionParams> get connectionParams => _params.stream;
}
