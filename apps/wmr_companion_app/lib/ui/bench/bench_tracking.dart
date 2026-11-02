import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

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
        'Connect glasses and tap Re-detect to enable 6DoF only. '
        'Without them, a tester can still run 3DoF only.';
  } else if (attachment?.disabled ?? false) {
    reason =
        '${choice.label} is not built in. Rebuild with '
        '--dart-define=${choice.buildFlag}=true.';
  } else if (selection.attachment.isLoading) {
    reason = 'Starting ${choice.label}...';
  } else if (attachment?.error != null) {
    reason = '${choice.label} failed to start: ${attachment!.error!.message}';
  } else if (attachment?.source != null) {
    reason = '${choice.label} does not report hand joints.';
  } else if (attachment?.message != null) {
    reason = attachment!.message!;
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
          'start. Switch the glasses to 3D (SpaceWalker) and tap Re-detect.';
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

/// Frames from the attached vendor source, shaped for the HUD.
final _benchSourceFramesProvider = StreamProvider<DebugPoses>((ref) {
  final source = ref
      .watch(debugTrackingSourceProvider)
      .attachment
      .value
      ?.source;
  if (source == null) return const Stream<DebugPoses>.empty();
  return source.frames.map(
    (frame) => DebugPoses(head: frame.head?.pose, tracking: frame),
  );
});

/// The live tracking sample behind the bench HUD.
///
/// It reads the attached source's frames directly, so the HUD draws exactly
/// the joints the pose recorder saves. With no source the stream stays empty
/// instead of starting the BLE transport just to read a head pose that cannot
/// arrive. The simulated source is driven by the debug viewer, so that choice
/// delegates to its stream.
final benchLivePosesProvider = Provider<AsyncValue<DebugPoses>>((ref) {
  final selection = ref.watch(debugTrackingSourceProvider);
  if (selection.choice == DebugTrackingSource.simulated) {
    return ref.watch(debugPosesProvider(DebugSource.real));
  }
  return ref.watch(_benchSourceFramesProvider);
});

/// One hand as the bench HUD draws it.
class BenchHandSnapshot {
  const BenchHandSnapshot({required this.hand, required this.joints});

  final TrackedHand hand;

  /// Tracked joints keyed by OpenXR joint, including an explicit palm pose.
  final Map<HandJoint, TrackedPose> joints;

  String get label => hand == TrackedHand.left ? 'LEFT' : 'RIGHT';

  bool get hasJoints => joints.isNotEmpty;
}

/// Splits the latest tracking frame into the two hands, left first.
List<BenchHandSnapshot> benchHandSnapshots(TrackingFrame? frame) => [
  BenchHandSnapshot(hand: TrackedHand.left, joints: _joints(frame?.leftHand)),
  BenchHandSnapshot(hand: TrackedHand.right, joints: _joints(frame?.rightHand)),
];

Map<HandJoint, TrackedPose> _joints(HandPose? hand) {
  if (hand == null) return const {};
  final joints = Map<HandJoint, TrackedPose>.of(hand.joints);
  final palm = hand.palm;
  if (palm != null) joints[HandJoint.palm] = palm;
  return joints;
}

/// How far the head has moved recently, and whether that is real 6DoF.
class BenchHeadMotion {
  const BenchHeadMotion({required this.travelMeters, required this.samples});

  /// Largest translation distance from the oldest sample in the window.
  final double travelMeters;

  /// Samples in the window; fewer than two cannot show motion.
  final int samples;

  /// One centimetre over the window is motion, not sensor jitter.
  static const double movingThresholdMeters = 0.01;

  bool get moving => samples >= 2 && travelMeters >= movingThresholdMeters;

  String get status =>
      moving ? '6DoF head pose: moving' : '0DoF head pose: static';

  String get deltaLabel =>
      samples < 2 ? 'Δ —' : 'Δ ${(travelMeters * 100).toStringAsFixed(1)} cm';
}

/// A short sliding window of head translations.
///
/// The window is measured in samples rather than wall time so widget tests do
/// not depend on the host clock. At the debug viewer's 30 Hz, 90 samples cover
/// the last three seconds.
class BenchHeadMotionTracker {
  BenchHeadMotionTracker({this.windowSamples = 90});

  final int windowSamples;
  final List<Vector3> _samples = [];

  void add(Pose? head) {
    if (head == null) {
      _samples.clear();
      return;
    }
    _samples.add(head.translation.clone());
    if (_samples.length > windowSamples) _samples.removeAt(0);
  }

  BenchHeadMotion get motion {
    if (_samples.length < 2) {
      return BenchHeadMotion(travelMeters: 0, samples: _samples.length);
    }
    final base = _samples.first;
    var travel = 0.0;
    for (final sample in _samples) {
      final distance = (sample - base).length;
      if (distance > travel) travel = distance;
    }
    return BenchHeadMotion(travelMeters: travel, samples: _samples.length);
  }
}
