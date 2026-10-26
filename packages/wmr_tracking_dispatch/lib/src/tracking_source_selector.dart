import 'package:wmr_tracking/wmr_tracking.dart';

import 'glasses_detection.dart';
import 'glasses_detector.dart';

/// Which vendor builds are enabled by the app's default-off Dart flags.
///
/// The selector never calls [GlassesDetector.detect] when none is enabled, so
/// flag-off paths stay channel-free.
class TrackingSourceFlags {
  const TrackingSourceFlags({
    this.viture = false,
    this.xreal = false,
    this.androidXr = false,
  });

  final bool viture;
  final bool xreal;
  final bool androidXr;

  bool get any => viture || xreal || androidXr;

  bool enabledFor(GlassesVendor vendor) => switch (vendor) {
    GlassesVendor.viture => viture,
    GlassesVendor.xreal => xreal,
    GlassesVendor.androidXr => androidXr,
    GlassesVendor.none => false,
  };
}

/// The outcome of [TrackingSourceSelector.select].
enum TrackingSelectionStatus {
  /// A source was created, started and returned.
  attached,

  /// Glasses were detected but this build does not include their plugin.
  unsupported,

  /// The plugin is built but the runtime, relay or permission is unavailable.
  unavailable,

  /// A runtime permission needed by the detected source was denied.
  permissionDenied,

  /// No glasses were detected, or every vendor flag is off.
  none,
}

/// A typed selector result: the attached source, or why none was attached.
class TrackingSelection {
  const TrackingSelection({
    required this.status,
    this.source,
    this.detection,
    this.message,
  });

  final TrackingSelectionStatus status;
  final TrackingSource? source;
  final GlassesDetection? detection;
  final String? message;

  bool get hasSource => source != null;

  @override
  String toString() =>
      'TrackingSelection(${status.name}'
      '${detection == null ? '' : ', ${detection!.vendor.wireName}'}'
      '${message == null ? '' : ', $message'})';
}

/// Picks the tracking source for the natively detected glasses vendor.
///
/// Detection runs before any Unity command. The selected plugin still performs
/// its own vendor model check (`queryGlassesModel`) as a second confirmation.
class TrackingSourceSelector {
  const TrackingSourceSelector({
    required this.detector,
    required this.flags,
    this.vitureSource,
    this.xrealSource,
    this.androidXrSource,
  });

  final GlassesDetector detector;
  final TrackingSourceFlags flags;

  /// Factories return null when the plugin's flag is off or the relay is not
  /// linked. They are only called for the detected vendor.
  final Future<TrackingSource?> Function()? vitureSource;
  final Future<TrackingSource?> Function()? xrealSource;
  final Future<TrackingSource?> Function()? androidXrSource;

  Future<TrackingSelection> select() async {
    if (!flags.any) {
      return const TrackingSelection(
        status: TrackingSelectionStatus.none,
        message: 'All vendor tracking flags are off; no detector call was made',
      );
    }

    GlassesDetection detection;
    try {
      detection = await detector.detect();
    } catch (error) {
      return TrackingSelection(
        status: TrackingSelectionStatus.unavailable,
        message: 'Native glasses detection failed: $error',
      );
    }
    if (!detection.hasVendor) {
      return TrackingSelection(
        status: TrackingSelectionStatus.none,
        detection: detection,
        message: _detectionMessage(detection),
      );
    }
    if (!flags.enabledFor(detection.vendor)) {
      return TrackingSelection(
        status: TrackingSelectionStatus.unsupported,
        detection: detection,
        message:
            '${detection.vendor.wireName} glasses were detected but this '
            'build does not enable that vendor',
      );
    }

    final factory = switch (detection.vendor) {
      GlassesVendor.viture => vitureSource,
      GlassesVendor.xreal => xrealSource,
      GlassesVendor.androidXr => androidXrSource,
      GlassesVendor.none => null,
    };
    if (factory == null) {
      return TrackingSelection(
        status: TrackingSelectionStatus.unavailable,
        detection: detection,
        message: 'No ${detection.vendor.wireName} source factory is configured',
      );
    }

    TrackingSource? source;
    try {
      source = await factory();
    } catch (error) {
      return TrackingSelection(
        status: TrackingSelectionStatus.unavailable,
        detection: detection,
        message: 'Creating the ${detection.vendor.wireName} source failed: '
            '$error',
      );
    }
    if (source == null) {
      return TrackingSelection(
        status: TrackingSelectionStatus.unavailable,
        detection: detection,
        message:
            'The ${detection.vendor.wireName} source is not available in this '
            'build (flag off or relay not linked)',
      );
    }

    try {
      await source.start();
    } on TrackingException catch (error) {
      await _disposeQuietly(source);
      return TrackingSelection(
        status: _statusFor(error.kind),
        detection: detection,
        message: error.message,
      );
    } catch (error) {
      await _disposeQuietly(source);
      return TrackingSelection(
        status: TrackingSelectionStatus.unavailable,
        detection: detection,
        message: 'Starting the ${detection.vendor.wireName} source failed: '
            '$error',
      );
    }

    return TrackingSelection(
      status: TrackingSelectionStatus.attached,
      source: source,
      detection: detection,
      message: 'Attached ${detection.vendor.wireName} tracking',
    );
  }

  static TrackingSelectionStatus _statusFor(TrackingExceptionKind kind) =>
      switch (kind) {
        TrackingExceptionKind.unsupported => TrackingSelectionStatus.unsupported,
        TrackingExceptionKind.permissionDenied =>
          TrackingSelectionStatus.permissionDenied,
        TrackingExceptionKind.unavailable ||
        TrackingExceptionKind.protocol ||
        TrackingExceptionKind.closed => TrackingSelectionStatus.unavailable,
      };

  static String _detectionMessage(GlassesDetection detection) =>
      switch (detection.reason) {
        GlassesDetectionReason.usbPermissionDenied =>
          'USB access was denied, so no glasses vendor could be detected',
        GlassesDetectionReason.usbAmbiguous =>
          'Both VITURE and XREAL USB devices are attached; refusing to guess',
        GlassesDetectionReason.detectorUnavailable =>
          'The native glasses detector is not linked into this build',
        GlassesDetectionReason.detectorFailed =>
          'The native glasses detector failed: ${detection.detail ?? ''}'
              .trim(),
        _ => 'No VITURE, XREAL or Android XR glasses were detected',
      };

  static Future<void> _disposeQuietly(TrackingSource source) async {
    try {
      await source.dispose();
    } catch (_) {
      // The source is already unusable; keep the original failure.
    }
  }
}
