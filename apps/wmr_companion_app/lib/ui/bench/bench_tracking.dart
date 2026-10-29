import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../debug/debug_providers.dart';

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
/// debug viewer). A source only counts once it has started and declared hand
/// joints; a missing build flag or a failed start leaves 6DoF only disabled
/// with the typed reason.
final benchHandTrackingProvider = Provider<BenchHandTracking>((ref) {
  final selection = ref.watch(debugTrackingSourceProvider);
  final attachment = selection.attachment.value;
  final source = attachment?.source;
  if (source == null) {
    final choice = selection.choice;
    if (choice == DebugTrackingSource.none) {
      return const BenchHandTracking(
        reason:
            'Attach a hand-tracking source below to enable 6DoF only. '
            'Without it, a tester can still run 3DoF only.',
      );
    }
    if (attachment?.disabled ?? false) {
      return BenchHandTracking(
        label: choice.label,
        reason:
            '${choice.label} is not built in. Rebuild with '
            '--dart-define=${choice.buildFlag}=true.',
      );
    }
    final error = attachment?.error;
    if (error != null) {
      return BenchHandTracking(
        label: choice.label,
        reason: '${choice.label} failed to start: ${error.message}',
      );
    }
    return BenchHandTracking(
      label: choice.label,
      reason: 'Starting ${choice.label}...',
    );
  }
  final capabilities = source.capabilities;
  if (!capabilities.hasHandTracking) {
    return BenchHandTracking(
      runtime: source.vendor.name,
      label: selection.choice.label,
      reason: '${selection.choice.label} does not report hand joints.',
    );
  }
  return BenchHandTracking(
    available: true,
    runtime: source.vendor.name,
    label: selection.choice.label,
  );
});
