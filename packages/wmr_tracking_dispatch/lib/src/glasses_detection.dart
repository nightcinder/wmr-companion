import 'package:wmr_tracking/wmr_tracking.dart';

/// A vendor the native detector can identify before Unity starts.
enum GlassesVendor {
  viture('viture'),
  xreal('xreal'),
  androidXr('androidXr'),
  none('none');

  const GlassesVendor(this.wireName);

  final String wireName;

  /// The matching [TrackingVendor], or null for [GlassesVendor.none].
  TrackingVendor? get trackingVendor => switch (this) {
    GlassesVendor.viture => TrackingVendor.viture,
    GlassesVendor.xreal => TrackingVendor.xreal,
    GlassesVendor.androidXr => TrackingVendor.androidXr,
    GlassesVendor.none => null,
  };

  static GlassesVendor fromWireName(Object? value) {
    for (final vendor in GlassesVendor.values) {
      if (vendor.wireName == value) return vendor;
    }
    return GlassesVendor.none;
  }
}

/// The Android host the app is running on.
///
/// The Neckband and Beam Pro are vendor compute units; `phone` covers a plain
/// phone or tablet and `unknown` covers a host whose model did not match any
/// configured marker.
enum GlassesHost {
  neckband('neckband'),
  beamPro('beamPro'),
  phone('phone'),
  unknown('unknown');

  const GlassesHost(this.wireName);

  final String wireName;

  static GlassesHost fromWireName(Object? value) {
    for (final host in GlassesHost.values) {
      if (host.wireName == value) return host;
    }
    return GlassesHost.unknown;
  }
}

/// Why a detection did not produce a vendor.
abstract final class GlassesDetectionReason {
  /// The flag-gated detector was not called.
  static const String flagsOff = 'flagsOff';

  /// No configured USB vendor/product ID and no host marker matched.
  static const String noMatch = 'noMatch';

  /// Both VITURE and XREAL USB IDs were present; dispatch fails closed.
  static const String usbAmbiguous = 'usbAmbiguous';

  /// USB devices could not be inspected because the host denied access.
  static const String usbPermissionDenied = 'usbPermissionDenied';

  /// The native detector is not linked into this build.
  static const String detectorUnavailable = 'detectorUnavailable';

  /// The native detector threw or returned an unreadable result.
  static const String detectorFailed = 'detectorFailed';
}

/// The typed result of the native, pre-Unity glasses detection.
class GlassesDetection {
  const GlassesDetection({
    required this.vendor,
    required this.host,
    this.usbPermissionGranted = false,
    this.reason,
    this.detail,
  });

  static const GlassesDetection none = GlassesDetection(
    vendor: GlassesVendor.none,
    host: GlassesHost.unknown,
  );

  final GlassesVendor vendor;
  final GlassesHost host;

  /// Whether every matching USB device granted access to the app.
  final bool usbPermissionGranted;

  /// A [GlassesDetectionReason] constant, or null on a clean match.
  final String? reason;

  /// Human-readable context for logs and the selector status.
  final String? detail;

  bool get hasVendor => vendor != GlassesVendor.none;

  /// Parses the Kotlin plugin's map. Unknown vendors fail closed.
  factory GlassesDetection.fromMap(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('glasses detection must be a map');
    }
    return GlassesDetection(
      vendor: GlassesVendor.fromWireName(raw['vendor']),
      host: GlassesHost.fromWireName(raw['host']),
      usbPermissionGranted: raw['usbPermissionGranted'] == true,
      reason: raw['reason'] is String ? raw['reason'] as String : null,
      detail: raw['detail'] is String ? raw['detail'] as String : null,
    );
  }

  Map<String, Object?> toMap() => {
    'vendor': vendor.wireName,
    'host': host.wireName,
    'usbPermissionGranted': usbPermissionGranted,
    if (reason != null) 'reason': reason,
    if (detail != null) 'detail': detail,
  };

  @override
  String toString() =>
      'GlassesDetection(${vendor.wireName}, host: ${host.wireName}'
      '${reason == null ? '' : ', reason: $reason'})';
}
