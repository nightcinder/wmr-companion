import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../debug/debug_providers.dart';
import 'bench_pose.dart';

/// Whether the bench can take a 6DoF pose capture right now.
class BenchHandTracking {
  const BenchHandTracking({
    this.available = false,
    this.runtime,
    this.label,
    this.reason,
  });

  /// True when a started source reports hand joints.
  final bool available;

  /// The runtime name used in capture file names and the manifest.
  final String? runtime;

  /// The source label shown to the tester.
  final String? label;

  /// Why 6DoF only is unavailable, when it is.
  final String? reason;
}

/// The hand-tracking source selected on the bench page (and shared with the
/// debug viewer). Availability comes from the same gate the pose step uses
/// ([benchPoseAvailabilityProvider]); this only adds the label and a
/// tester-facing reason for the disabled mode button.
final benchHandTrackingProvider = Provider<BenchHandTracking>((ref) {
  final selection = ref.watch(debugTrackingSourceProvider);
  final availability = ref.watch(benchPoseAvailabilityProvider);
  if (availability.available) {
    return BenchHandTracking(
      available: true,
      runtime: availability.runtime,
      label: selection.choice.label,
    );
  }
  final attachment = selection.attachment.value;
  final choice = selection.choice;
  String reason;
  if (choice == DebugTrackingSource.none) {
    reason =
        'Attach a hand-tracking source below to enable 6DoF only. '
        'Without it, a tester can still run 3DoF only.';
  } else if (attachment?.disabled ?? false) {
    reason =
        '${choice.label} is not built in. Rebuild with '
        '--dart-define=${choice.buildFlag}=true.';
  } else if (attachment?.error != null) {
    reason = '${choice.label} failed to start: ${attachment!.error!.message}';
  } else if (attachment?.source != null) {
    reason = '${choice.label} does not report hand joints.';
  } else {
    reason = 'Starting ${choice.label}...';
  }
  return BenchHandTracking(label: choice.label, reason: reason);
});
