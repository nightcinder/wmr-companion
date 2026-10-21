import 'dart:async';
import 'dart:typed_data';

import 'ble_transport.dart';

/// Bluetooth radio state, independent of any BLE package.
enum BleAvailability {
  unknown,
  resetting,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

/// A connect or disconnect reported by the platform.
class AdapterConnectionEvent {
  const AdapterConnectionEvent({required this.connected, this.error});

  final bool connected;

  /// Platform error text when the change was not requested by the app.
  final String? error;
}

/// A connection interval reported by the platform (Android only).
class AdapterConnectionParams {
  const AdapterConnectionParams({
    required this.deviceId,
    required this.intervalUs,
  });

  final String deviceId;
  final int intervalUs;
}

/// The thin layer between [UniversalBleTransport] and a BLE package.
///
/// Every method maps to one package call, so the transport's sequencing can
/// be unit tested with a fake. Implementations throw on failure; the
/// transport classifies the errors.
abstract class BleAdapter {
  /// Whether [requestHighConnectionPriority] does anything on this platform.
  bool get supportsConnectionPriority;

  /// Whether runtime permissions are already granted.
  Future<bool> hasPermissions();

  /// Requests the runtime permissions. Throws if the user denies them.
  Future<void> requestPermissions();

  Future<BleAvailability> availability();
  Stream<BleAvailability> get availabilityChanges;

  Stream<BleScanResult> get scanResults;
  Future<void> startScan({
    required List<String> withServices,
    required List<String> withNamePrefixes,
  });
  Future<void> stopScan();

  /// Completes when the link is up; throws if it could not be established.
  Future<void> connect(String deviceId);
  Future<void> disconnect(String deviceId);
  Stream<AdapterConnectionEvent> connectionEvents(String deviceId);

  /// Requests [mtu] and returns the value the stack reports afterwards,
  /// which may differ from what was asked for.
  Future<int> requestMtu(String deviceId, int mtu);

  Future<void> requestHighConnectionPriority(String deviceId);

  Future<List<BleServiceInfo>> discoverServices(String deviceId);

  /// Writes the CCC descriptor to enable notifications.
  Future<void> enableNotifications(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );

  /// Raw notification payloads. Must not do any work per event.
  Stream<Uint8List> notifications(String deviceId, String characteristicUuid);

  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );

  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    required bool withoutResponse,
  });

  Future<int> readRssi(String deviceId);

  /// Connection interval updates; empty where the platform has no callback.
  Stream<AdapterConnectionParams> get connectionParams;
}
