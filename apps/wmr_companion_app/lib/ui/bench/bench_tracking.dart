import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../debug/debug_providers.dart';
import 'bench_pose.dart';

/// Whether the bench can take a 6DoF pose capture right now, and the
/// tester-facing 0DoF/6DoF status that explains it.
class BenchHandTracking {
  const BenchHandTracking({
    this.available = false,
    this.runtime,
    this.label,
    this.reason,
    this.status = '0DoF: no hand-tracking source attached.',
  });

  /// True when a started source reports hand joints.
  final bool available;

  /// The runtime name used in capture file names and the manifest.
  final String? runtime;

  /// The source label shown to the tester.
  final String? label;

  /// Why 6DoF only is unavailable, when it is.
  final String? reason;

  /// One-line 0DoF/6DoF summary, always shown above the source selector.
  final String status;
}

/// The hand-tracking source selected on the bench page (and shared with the
/// debug viewer). Availability comes from the same gate the pose step uses
/// ([benchPoseAvailabilityProvider]); this only adds the label, a
/// tester-facing reason for the disabled mode button, and the 0DoF/6DoF
/// status line.
final benchHandTrackingProvider = Provider<BenchHandTracking>((ref) {
  final selection = ref.watch(debugTrackingSourceProvider);
  final availability = ref.watch(benchPoseAvailabilityProvider);
  final choice = selection.choice;
  final attachment = selection.attachment.value;
  if (availability.available) {
    return BenchHandTracking(
      available: true,
      runtime: availability.runtime,
      label: choice.label,
      status:
          '6DoF: ${choice.label} hand tracking attached '
          '(${availability.runtime} runtime).',
    );
  }
  String reason;
  if (choice == DebugTrackingSource.none) {
    reason =
        'Attach a hand-tracking source below to enable 6DoF only. '
        'Without it, a tester can still run 3DoF only.';
  } else if (attachment?.disabled ?? false) {
    reason =
        '${choice.label} is not built in. Rebuild with '
        '--dart-define=${choice.buildFlag}=true.';
  } else if (selection.attachment.isLoading) {
    reason = 'Starting ${choice.label}...';
  } else if (attachment?.error != null) {
    reason = '${choice.label} failed to start: ${attachment!.error!.message}';
  } else if (attachment?.message != null) {
    reason = attachment!.message!;
  } else if (attachment?.source != null) {
    reason = '${choice.label} does not report hand joints.';
  } else {
    reason = 'Starting ${choice.label}...';
  }
  return BenchHandTracking(
    label: choice.label,
    reason: reason,
    status: _status(selection, attachment),
  );
});

/// The 0DoF summary for a source that is not delivering hand joints.
String _status(
  DebugTrackingSelection selection,
  DebugTrackingAttachment? attachment,
) {
  final choice = selection.choice;
  if (choice == DebugTrackingSource.none) {
    return '0DoF: no hand-tracking source attached.';
  }
  if (selection.attachment.isLoading) return 'Starting ${choice.label}...';
  final error = attachment?.error;
  if (error != null) {
    if (_stereoInactive(error.message)) {
      return '0DoF: VITURE XR stereo is inactive, so hand tracking cannot '
          'start. Switch the glasses to 3D (SpaceWalker) and select the '
          'source again.';
    }
    return '0DoF: ${choice.label} failed to start (${error.kind.name}).';
  }
  if (attachment?.disabled ?? false) {
    return '0DoF: ${choice.label} is not built into this app.';
  }
  if (attachment?.source != null) {
    return '0DoF: ${choice.label} does not report hand joints.';
  }
  final message = attachment?.message;
  return message == null
      ? '0DoF: ${choice.label} is not attached.'
      : '0DoF: $message';
}

/// The VITURE Unity relay fails a 2D (SpaceWalker off) player with this
/// message; the tester can only fix it on the glasses.
bool _stereoInactive(String message) {
  final lower = message.toLowerCase();
  return lower.contains('stereo 3d') ||
      lower.contains('spacewalker') ||
      lower.contains('running in 2d');
}
