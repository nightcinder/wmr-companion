import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart' as ub;

import 'ble_adapter.dart';
import 'ble_transport.dart';

/// [BleAdapter] backed by the `universal_ble` package (3.1.x).
///
/// Untested on hardware. Each method is a direct call; the sequencing lives
/// in `UniversalBleTransport`.
class UniversalBleAdapter implements BleAdapter {
  UniversalBleAdapter() {
    // Global setter: the last assignment wins, so only one adapter should
    // be alive. Android only (API 26+); never fires elsewhere.
    ub.UniversalBle.onConnectionParametersChange = (update) {
      if (_params.isClosed) return;
      _params.add(
        AdapterConnectionParams(
          deviceId: update.deviceId,
          intervalUs: (update.interval * 1250),
        ),
      );
    };
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
  Future<int> requestMtu(String deviceId, int mtu) =>
      ub.UniversalBle.requestMtu(deviceId, mtu);

  @override
  Future<void> requestHighConnectionPriority(String deviceId) =>
      ub.UniversalBle.requestConnectionPriority(
        deviceId,
        ub.BleConnectionPriority.highPerformance,
      );

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) async {
    final services = await ub.UniversalBle.discoverServices(deviceId);
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
  ) => ub.UniversalBle.subscribeNotifications(
    deviceId,
    serviceUuid,
    characteristicUuid,
  );

  @override
  Stream<Uint8List> notifications(String deviceId, String characteristicUuid) =>
      ub.UniversalBle.characteristicValueStream(deviceId, characteristicUuid);

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => ub.UniversalBle.read(deviceId, serviceUuid, characteristicUuid);

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
