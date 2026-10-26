import 'package:flutter/services.dart';

import 'glasses_detection.dart';

/// The seam behind the native pre-Unity glasses detector.
abstract interface class GlassesDetector {
  Future<GlassesDetection> detect();
}

/// Calls the Kotlin `wmr_tracking_dispatch/methods` channel.
///
/// The selector only calls this when at least one vendor flag is enabled, so a
/// flag-off build never touches the channel.
class PlatformGlassesDetector implements GlassesDetector {
  const PlatformGlassesDetector([
    this._channel = const MethodChannel(channelName),
  ]);

  static const String channelName = 'wmr_tracking_dispatch/methods';

  final MethodChannel _channel;

  @override
  Future<GlassesDetection> detect() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('detectGlasses');
      return GlassesDetection.fromMap(raw);
    } on MissingPluginException {
      return const GlassesDetection(
        vendor: GlassesVendor.none,
        host: GlassesHost.unknown,
        reason: GlassesDetectionReason.detectorUnavailable,
        detail: 'wmr_tracking_dispatch is not linked into this build',
      );
    } on PlatformException catch (error) {
      return GlassesDetection(
        vendor: GlassesVendor.none,
        host: GlassesHost.unknown,
        reason: GlassesDetectionReason.detectorFailed,
        detail: error.message ?? error.code,
      );
    } on FormatException catch (error) {
      return GlassesDetection(
        vendor: GlassesVendor.none,
        host: GlassesHost.unknown,
        reason: GlassesDetectionReason.detectorFailed,
        detail: error.message,
      );
    }
  }

  /// Overrides the USB IDs used by the detector for this process.
  ///
  /// Product IDs are unknown in the public docs, so this is the supported way
  /// to supply them without shipping a guess.
  Future<void> configureIds({
    List<int>? vitureVendorIds,
    List<int>? vitureProductIds,
    List<int>? xrealVendorIds,
    List<int>? xrealProductIds,
  }) => _channel.invokeMethod<void>('configureIds', {
    'vitureVendorIds': ?vitureVendorIds,
    'vitureProductIds': ?vitureProductIds,
    'xrealVendorIds': ?xrealVendorIds,
    'xrealProductIds': ?xrealProductIds,
  });
}
