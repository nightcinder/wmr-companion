import 'package:flutter/services.dart';

import 'glasses_detector.dart';

/// One USB interface's class triple.
///
/// Values are kept raw: a device with a class the app does not know about is
/// still recorded instead of being dropped.
class UsbInterfaceSnapshot {
  const UsbInterfaceSnapshot({
    required this.interfaceClass,
    required this.interfaceSubclass,
    required this.interfaceProtocol,
  });

  final int interfaceClass;
  final int interfaceSubclass;
  final int interfaceProtocol;

  factory UsbInterfaceSnapshot.fromMap(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('usb interface must be a map');
    }
    return UsbInterfaceSnapshot(
      interfaceClass: _int(raw['class']),
      interfaceSubclass: _int(raw['subclass']),
      interfaceProtocol: _int(raw['protocol']),
    );
  }

  Map<String, Object?> toJson() => {
    'class': interfaceClass,
    'subclass': interfaceSubclass,
    'protocol': interfaceProtocol,
  };
}

/// One USB device and every interface it exposes.
class UsbDeviceSnapshot {
  const UsbDeviceSnapshot({
    required this.vendorId,
    required this.productId,
    this.deviceName,
    this.manufacturerName,
    this.productName,
    this.interfaces = const [],
  });

  final int vendorId;
  final int productId;

  /// The host path (for example `/dev/bus/usb/001/002`), when reported.
  final String? deviceName;

  /// The device's self-reported manufacturer string, when it has one.
  final String? manufacturerName;

  /// The device's self-reported product string, when it has one.
  final String? productName;

  final List<UsbInterfaceSnapshot> interfaces;

  factory UsbDeviceSnapshot.fromMap(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('usb device must be a map');
    }
    return UsbDeviceSnapshot(
      vendorId: _int(raw['vendor_id']),
      productId: _int(raw['product_id']),
      deviceName: _string(raw['device_name']),
      manufacturerName: _string(raw['manufacturer']),
      productName: _string(raw['product']),
      interfaces: [
        for (final value in _list(raw['interfaces']))
          UsbInterfaceSnapshot.fromMap(value),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'vendor_id': vendorId,
    'product_id': productId,
    if (deviceName != null) 'device_name': deviceName,
    if (manufacturerName != null) 'manufacturer': manufacturerName,
    if (productName != null) 'product': productName,
    'interfaces': [for (final interface in interfaces) interface.toJson()],
  };
}

/// One display the host reports.
///
/// [type] is the wire value verbatim: the Android probe classifies a display
/// as `external` when `Display.FLAG_PRESENTATION` is set and `builtIn`
/// otherwise, and any other value a host sends is preserved unchanged.
class ExternalDisplaySnapshot {
  const ExternalDisplaySnapshot({
    required this.id,
    required this.type,
    this.name,
    this.width,
    this.height,
    this.refreshRateHz,
  });

  final int id;
  final String type;
  final String? name;
  final int? width;
  final int? height;
  final double? refreshRateHz;

  /// The one classification the Android probe emits for a display that is
  /// not the headset's built-in panel. Any other value stays non-external but
  /// remains in the snapshot.
  static const Set<String> externalTypes = {'external'};

  bool get isExternal => externalTypes.contains(type);

  factory ExternalDisplaySnapshot.fromMap(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('display must be a map');
    }
    return ExternalDisplaySnapshot(
      id: _int(raw['id']),
      type: _string(raw['type']) ?? 'unknown',
      name: _string(raw['name']),
      width: _nullableInt(raw['width']),
      height: _nullableInt(raw['height']),
      refreshRateHz: _nullableDouble(raw['refresh_rate_hz']),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'external': isExternal,
    if (name != null) 'name': name,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (refreshRateHz != null) 'refresh_rate_hz': refreshRateHz,
  };
}

/// One XR platform feature and whether the host reports it.
class XrSystemFeatureSnapshot {
  const XrSystemFeatureSnapshot({required this.name, required this.present});

  final String name;
  final bool present;

  factory XrSystemFeatureSnapshot.fromMap(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('xr feature must be a map');
    }
    return XrSystemFeatureSnapshot(
      name: _string(raw['name']) ?? _string(raw['feature']) ?? 'unknown',
      present: raw['present'] == true || raw['available'] == true,
    );
  }

  Map<String, Object?> toJson() => {'name': name, 'present': present};
}

/// Whether the native probe produced data.
enum DeviceEnvironmentProbeStatus {
  ok('ok'),
  unsupported('unsupported'),
  failed('failed');

  const DeviceEnvironmentProbeStatus(this.wireName);

  final String wireName;

  static DeviceEnvironmentProbeStatus fromWireName(Object? value) {
    for (final status in DeviceEnvironmentProbeStatus.values) {
      if (status.wireName == value) return status;
    }
    return DeviceEnvironmentProbeStatus.ok;
  }
}

/// Why a probe produced no environment data.
abstract final class DeviceEnvironmentReason {
  /// The native plugin is not linked into this build.
  static const String probeUnavailable = 'probeUnavailable';

  /// The native probe threw or returned an unreadable map.
  static const String probeFailed = 'probeFailed';
}

/// A snapshot of the USB, display and XR facts around the host.
///
/// The probe records what the host reports rather than deciding which devices
/// matter, so a new headset can be diagnosed before a vendor table knows it.
class DeviceEnvironmentSnapshot {
  const DeviceEnvironmentSnapshot({
    required this.capturedAt,
    this.status = DeviceEnvironmentProbeStatus.ok,
    this.reason,
    this.detail,
    this.usbHostAvailable = false,
    this.usbDevices = const [],
    this.displays = const [],
    this.xrFeatures = const [],
  });

  static const String format = 'wmr-device-environment/1';

  final DateTime capturedAt;
  final DeviceEnvironmentProbeStatus status;

  /// A [DeviceEnvironmentReason] constant when [status] is not ok.
  final String? reason;
  final String? detail;

  final bool usbHostAvailable;
  final List<UsbDeviceSnapshot> usbDevices;
  final List<ExternalDisplaySnapshot> displays;
  final List<XrSystemFeatureSnapshot> xrFeatures;

  /// Displays the host classified as external.
  List<ExternalDisplaySnapshot> get externalDisplays => [
    for (final display in displays)
      if (display.isExternal) display,
  ];

  /// Parses the native map. Unknown values are kept, not filtered.
  factory DeviceEnvironmentSnapshot.fromMap(
    Object? raw, {
    required DateTime capturedAt,
  }) {
    if (raw is! Map) {
      throw const FormatException('device environment must be a map');
    }
    final usb = raw['usb'];
    final usbMap = usb is Map ? usb : const {};
    final displayValue = raw['displays'];
    final displayItems = displayValue is Map
        ? displayValue['items']
        : displayValue;
    final features = raw['xr_features'];
    return DeviceEnvironmentSnapshot(
      capturedAt: capturedAt,
      status: DeviceEnvironmentProbeStatus.fromWireName(raw['status']),
      reason: _string(raw['reason']),
      detail: _string(raw['detail']),
      usbHostAvailable: usbMap['host_available'] == true,
      usbDevices: [
        for (final value in _list(usbMap['devices']))
          UsbDeviceSnapshot.fromMap(value),
      ],
      displays: [
        for (final value in _list(displayItems))
          ExternalDisplaySnapshot.fromMap(value),
      ],
      xrFeatures: [
        for (final value in _list(features))
          XrSystemFeatureSnapshot.fromMap(value),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'captured_at': capturedAt.toUtc().toIso8601String(),
    'status': status.wireName,
    if (reason != null) 'reason': reason,
    if (detail != null) 'detail': detail,
    'usb': {
      'host_available': usbHostAvailable,
      'devices': [for (final device in usbDevices) device.toJson()],
    },
    'displays': {
      'external_count': externalDisplays.length,
      'items': [for (final display in displays) display.toJson()],
    },
    'xr_features': [for (final feature in xrFeatures) feature.toJson()],
  };
}

/// The seam behind the native USB/display/XR probe.
abstract interface class DeviceEnvironmentProbe {
  Future<DeviceEnvironmentSnapshot> probe();
}

/// Calls the Kotlin `deviceEnvironment` method on the dispatch channel.
///
/// The app calls this only when a diagnostic bundle is exported, so a normal
/// run performs no probe.
class PlatformDeviceEnvironmentProbe implements DeviceEnvironmentProbe {
  const PlatformDeviceEnvironmentProbe([
    this._channel = const MethodChannel(PlatformGlassesDetector.channelName),
  ]);

  final MethodChannel _channel;

  @override
  Future<DeviceEnvironmentSnapshot> probe() async {
    final capturedAt = DateTime.now();
    try {
      final raw = await _channel.invokeMethod<Object?>('deviceEnvironment');
      return DeviceEnvironmentSnapshot.fromMap(raw, capturedAt: capturedAt);
    } on MissingPluginException {
      return DeviceEnvironmentSnapshot(
        capturedAt: capturedAt,
        status: DeviceEnvironmentProbeStatus.unsupported,
        reason: DeviceEnvironmentReason.probeUnavailable,
        detail: 'wmr_tracking_dispatch is not linked into this build',
      );
    } on PlatformException catch (error) {
      return DeviceEnvironmentSnapshot(
        capturedAt: capturedAt,
        status: DeviceEnvironmentProbeStatus.failed,
        reason: DeviceEnvironmentReason.probeFailed,
        detail: error.message ?? error.code,
      );
    } on FormatException catch (error) {
      return DeviceEnvironmentSnapshot(
        capturedAt: capturedAt,
        status: DeviceEnvironmentProbeStatus.failed,
        reason: DeviceEnvironmentReason.probeFailed,
        detail: error.message,
      );
    } on Object catch (error) {
      return DeviceEnvironmentSnapshot(
        capturedAt: capturedAt,
        status: DeviceEnvironmentProbeStatus.failed,
        reason: DeviceEnvironmentReason.probeFailed,
        detail: '$error',
      );
    }
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

double? _nullableDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

List<Object?> _list(Object? value) =>
    value is List ? [for (final item in value) item] : const [];
