import 'dart:async';
import 'dart:typed_data';

import 'package:wmr_core/ble/ble_transport.dart';

/// Bluetooth radio state, independent of any BLE package.
enum BleAvailability {
  unknown,
  resetting,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

/// App lifecycle as the host reports it.
///
/// The BLE package never reaches into Flutter's widget binding. A host that
/// has a lifecycle (the reference app does) forwards these states to
/// [UniversalBleTransport.handleAppLifecycle]. Scanning is suspended while the
/// app is not active and resumes with the same filters when the host returns;
/// connections are left alone.
enum BleAppLifecycle { resumed, inactive, paused, detached }

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

/// A failed adapter call that carries the ATT error code when the platform
/// reported one. [attError] is best effort: platforms word GATT failures
/// differently (Android reports status 128 for 0x80) and the real wording has
/// not been seen on hardware.
class BleAdapterException implements Exception {
  const BleAdapterException(this.message, {this.attError});

  final String message;
  final int? attError;

  @override
  String toString() => attError == null
      ? 'BleAdapterException: $message'
      : 'BleAdapterException(ATT 0x${attError!.toRadixString(16)}): $message';
}

/// Pulls an ATT error code out of a platform error message, or null. Matches
/// BlueZ's "ATT error: 0x80", Android's "status 128" / "status=128" and a
/// bare two-digit hex value such as "0x80". Guesses at wordings nobody has
/// seen from this bridge; the caller must treat null as "unknown", not "not
/// an ATT error".
int? parseAttError(String text) {
  final bluez = RegExp(
    r'ATT error:\s*0x([0-9a-f]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (bluez != null) return int.parse(bluez.group(1)!, radix: 16);
  final status = RegExp(
    r'status\D{0,3}(\d{1,3})\b',
    caseSensitive: false,
  ).firstMatch(text);
  if (status != null) return int.parse(status.group(1)!);
  final hex = RegExp(
    r'\b0x([0-9a-f]{2})\b',
    caseSensitive: false,
  ).firstMatch(text);
  if (hex != null) return int.parse(hex.group(1)!, radix: 16);
  return null;
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

  /// Writes the CCC descriptor to enable notifications. Throws a
  /// [BleAdapterException] with the ATT error where the platform gives one.
  Future<void> enableNotifications(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );

  /// Writes 0x0000 to the CCC descriptor.
  Future<void> disableNotifications(
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
