import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart' as ub;

import 'ble_adapter.dart';

import 'package:wmr_core/ble/ble_transport.dart';

/// [BleAdapter] backed by the `universal_ble` package (3.2.x).
///
/// Untested on hardware. Each method is a direct call; the sequencing lives
/// in `UniversalBleTransport`.
class UniversalBleAdapter implements BleAdapter {
  UniversalBleAdapter() {
    // Global setter: dispatch to every live adapter so creating a second
    // adapter never silently drops connection-interval updates on an earlier
    // one. Android only (API 26+); never fires elsewhere.
    _ensureConnectionParamsHook();
    _instances.add(WeakReference(this));
  }

  static final List<WeakReference<UniversalBleAdapter>> _instances = [];
  static bool _hookInstalled = false;

  static void _ensureConnectionParamsHook() {
    if (_hookInstalled) return;
    _hookInstalled = true;
    ub.UniversalBle.onConnectionParametersChange = (update) {
      _dispatchConnectionParams(update.deviceId, update.interval * 1250);
    };
  }

  static void _dispatchConnectionParams(String deviceId, int intervalUs) {
    final params = AdapterConnectionParams(
      deviceId: deviceId,
      intervalUs: intervalUs,
    );
    _instances.removeWhere((ref) {
      final adapter = ref.target;
      if (adapter == null) return true;
      if (!adapter._params.isClosed) {
        adapter._params.add(params);
      }
      return false;
    });
  }

  /// Dispatches a synthetic connection-parameters event through the shared
  /// callback for tests.
  static void dispatchConnectionParametersForTest(
    String deviceId,
    int intervalUnits,
  ) {
    _dispatchConnectionParams(deviceId, intervalUnits * 1250);
  }

  final StreamController<AdapterConnectionParams> _params =
      StreamController.broadcast();

  @override
  bool get supportsConnectionPriority =>
      ub.BleCapabilities.supportsConnectionPriorityApi;

  @override
  Future<bool> hasPermissions() => ub.UniversalBle.hasPermissions();

  @override
  Future<void> requestPermissions() => ub.UniversalBle.requestPermissions();

  @override
  Future<BleAvailability> availability() async =>
      _availability(await ub.UniversalBle.getBluetoothAvailabilityState());

  @override
  Stream<BleAvailability> get availabilityChanges =>
      ub.UniversalBle.availabilityStream.map(_availability);

  @override
  Stream<BleScanResult> get scanResults => ub.UniversalBle.scanStream.map(
    (d) => BleScanResult(
      deviceId: d.deviceId,
      name: d.name,
      rssi: d.rssi,
      serviceUuids: d.services,
    ),
  );

  @override
  Future<void> startScan({
    required List<String> withServices,
    required List<String> withNamePrefixes,
  }) => ub.UniversalBle.startScan(
    // The package ORs the conditions, so this matches the name or the service.
    scanFilter: ub.ScanFilter(
      withServices: withServices,
      withNamePrefix: withNamePrefixes,
    ),
  );

  @override
  Future<void> stopScan() => ub.UniversalBle.stopScan();

  @override
  Future<List<BleScanResult>> systemDevices({
    required List<String> withServices,
  }) async {
    final devices = await ub.UniversalBle.getSystemDevices(
      withServices: withServices,
    );
    return [
      for (final d in devices)
        BleScanResult(
          deviceId: d.deviceId,
          name: d.name,
          rssi: d.rssi,
          serviceUuids: d.services,
        ),
    ];
  }

  @override
  Future<void> connect(String deviceId) => ub.UniversalBle.connect(deviceId);

  @override
  Future<void> disconnect(String deviceId) =>
      ub.UniversalBle.disconnect(deviceId);

  @override
  Stream<AdapterConnectionEvent> connectionEvents(String deviceId) =>
      ub.UniversalBle.connectionChangeStream(deviceId).map(
        (c) => AdapterConnectionEvent(connected: c.isConnected, error: c.error),
      );

  @override
  Future<int> requestMtu(String deviceId, int mtu, {Duration? timeout}) =>
      ub.UniversalBle.requestMtu(deviceId, mtu, timeout: timeout);

  @override
  Future<void> requestHighConnectionPriority(String deviceId) =>
      ub.UniversalBle.requestConnectionPriority(
        deviceId,
        ub.BleConnectionPriority.highPerformance,
      );

  @override
  Future<List<BleServiceInfo>> discoverServices(
    String deviceId, {
    Duration? timeout,
  }) async {
    final services = await ub.UniversalBle.discoverServices(
      deviceId,
      timeout: timeout,
    );
    return [
      for (final s in services)
        BleServiceInfo(
          uuid: s.uuid,
          characteristicUuids: [for (final c in s.characteristics) c.uuid],
        ),
    ];
  }

  @override
  Future<void> enableNotifications(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => _translate(
    () => ub.UniversalBle.subscribeNotifications(
      deviceId,
      serviceUuid,
      characteristicUuid,
    ),
  );

  @override
  Future<void> disableNotifications(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => _translate(
    () =>
        ub.UniversalBle.unsubscribe(deviceId, serviceUuid, characteristicUuid),
  );

  /// Rethrows package errors as [BleAdapterException], with the ATT code when
  /// the message carries one. Untested against a real ATT 0x80.
  static Future<void> _translate(Future<void> Function() call) async {
    try {
      await call();
    } catch (e) {
      final text = e is ub.UniversalBleException
          ? '${e.message} ${e.details}'
          : '$e';
      throw BleAdapterException(text, attError: parseAttError(text));
    }
  }

  @override
  Stream<Uint8List> notifications(String deviceId, String characteristicUuid) =>
      ub.UniversalBle.characteristicValueStream(deviceId, characteristicUuid);

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid, {
    Duration? timeout,
  }) => ub.UniversalBle.read(
    deviceId,
    serviceUuid,
    characteristicUuid,
    timeout: timeout,
  );

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    required bool withoutResponse,
  }) => ub.UniversalBle.write(
    deviceId,
    serviceUuid,
    characteristicUuid,
    value,
    withoutResponse: withoutResponse,
  );

  @override
  Future<int> readRssi(String deviceId) => ub.UniversalBle.readRssi(deviceId);

  @override
  Stream<AdapterConnectionParams> get connectionParams => _params.stream;

  static BleAvailability _availability(ub.AvailabilityState s) => switch (s) {
    ub.AvailabilityState.unknown => BleAvailability.unknown,
    ub.AvailabilityState.resetting => BleAvailability.resetting,
    ub.AvailabilityState.unsupported => BleAvailability.unsupported,
    ub.AvailabilityState.unauthorized => BleAvailability.unauthorized,
    ub.AvailabilityState.poweredOff => BleAvailability.poweredOff,
    ub.AvailabilityState.poweredOn => BleAvailability.poweredOn,
  };
}
