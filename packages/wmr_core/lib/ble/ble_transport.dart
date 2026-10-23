import 'dart:async';
import 'dart:typed_data';

/// A device seen during a scan.
class BleScanResult {
  const BleScanResult({
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.serviceUuids = const [],
  });

  final String deviceId;
  final String? name;
  final int? rssi;
  final List<String> serviceUuids;
}

/// A discovered GATT service and the UUIDs of its characteristics.
class BleServiceInfo {
  const BleServiceInfo({required this.uuid, required this.characteristicUuids});

  final String uuid;
  final List<String> characteristicUuids;
}

/// One notification, stamped with the phone's monotonic clock the moment the
/// transport received it.
class BleNotification {
  const BleNotification({required this.value, required this.receivedAtUs});

  final Uint8List value;

  /// Microseconds on the transport's [MonotonicClock]. Only meaningful
  /// relative to other timestamps from the same clock; never compare it with
  /// ESP32 timestamps.
  final int receivedAtUs;
}

enum BleConnectionState { disconnected, connecting, connected, disconnecting }

/// Link parameters. Fields are null when the platform does not expose them.
class BleConnectionInfo {
  const BleConnectionInfo({
    this.mtu,
    this.rssi,
    this.connectionIntervalUs,
    this.phy,
  });

  final int? mtu;
  final int? rssi;
  final int? connectionIntervalUs;
  final String? phy;
}

/// Monotonic microsecond clock shared by a transport and its consumers.
class MonotonicClock {
  MonotonicClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  int get nowUs => _stopwatch.elapsedMicroseconds;
}

enum BleStreamFaultKind {
  /// The bridge refused to enable a stream because the other one is active
  /// (ATT error 0x80).
  otherStreamActive,

  /// Enabling notifications failed for another reason.
  enableFailed,

  /// Writing 0x0000 to the previously active characteristic failed, so the
  /// new one was not enabled.
  disableFailed,
}

/// Delivered as an error on the stream returned by [BleTransport.subscribe]
/// when the CCC write behind it failed. Never swallowed: the consumer must
/// surface it.
class BleStreamException implements Exception {
  const BleStreamException(
    this.kind,
    this.characteristicUuid,
    this.message, {
    this.attError,
  });

  final BleStreamFaultKind kind;
  final String characteristicUuid;
  final String message;
  final int? attError;

  @override
  String toString() => 'BleStreamException(${kind.name}): $message';
}

/// BLE GATT central operations used by the app. Implementations must stamp
/// every notification with [clock] as early as possible.
abstract class BleTransport {
  MonotonicClock get clock;

  Stream<BleScanResult> scan({List<String> withServices = const []});
  Future<void> stopScan();

  Future<void> connect(String deviceId);
  Future<void> disconnect(String deviceId);
  Stream<BleConnectionState> connectionState(String deviceId);

  Future<List<BleServiceInfo>> discoverServices(String deviceId);

  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );

  /// Writes 0x0000 to the characteristic's CCC. The bridge's FF11, FF12 and
  /// FF14 streams are mutually exclusive, so [subscribe] to one disables the
  /// active one first (in that order); this is for turning a stream off
  /// without enabling another.
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );

  /// Reads a characteristic value (long values included). Used for the FF13
  /// config window and the FF11 status; never at stream rate.
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
    bool withoutResponse = false,
  });

  Future<BleConnectionInfo> connectionInfo(String deviceId);

  Future<void> dispose();
}

extension BleTransportMultiple on BleTransport {
  /// Subscribes to [characteristicUuid] on multiple devices and merges their
  /// notification streams.
  Stream<BleNotification> subscribeMultiple(
    Iterable<String> deviceIds,
    String serviceUuid,
    String characteristicUuid,
  ) {
    late final StreamController<BleNotification> ctl;
    final subs = <StreamSubscription<BleNotification>>[];
    ctl = StreamController<BleNotification>.broadcast(
      onListen: () {
        for (final id in deviceIds) {
          subs.add(
            subscribe(
              id,
              serviceUuid,
              characteristicUuid,
            ).listen(ctl.add, onError: ctl.addError),
          );
        }
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
        subs.clear();
      },
    );
    return ctl.stream;
  }
}
