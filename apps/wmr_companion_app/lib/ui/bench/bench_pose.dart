import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../debug/debug_providers.dart';
import '../debug/pose_recording_store.dart';

/// One guided 6DoF pose segment, from `filter-spec` rev 4 section 8.
enum PoseSegment {
  still(
    'still',
    'Hold still',
    Duration(seconds: 10),
    'Rest the controller in your hand and brace your arm. Keep it still for '
        '10 s.',
  ),
  drifting(
    'drifting',
    'Held, drifting',
    Duration(seconds: 10),
    'Hold as if you were aiming, and let the controller wander slowly for '
        '10 s.',
  ),
  slowPan(
    'slow_pan',
    'Slow pan',
    Duration(seconds: 18),
    'Move 30 cm sideways over 3 s, then back. Do that 3 times.',
  ),
  mediumPan(
    'medium_pan',
    'Medium pan',
    Duration(seconds: 10),
    'Move 50 cm sideways in 1 s, then back. Keep going for 10 s.',
  ),
  fastFlick(
    'fast_flick',
    'Fast flick',
    Duration(seconds: 20),
    'Flick 45 cm in 0.3 s, pause, then bring it back. Do that 10 times.',
  );

  const PoseSegment(this.id, this.title, this.defaultDuration, this.prompt);

  /// Manifest and file-name key.
  final String id;

  /// Short title for the step screen.
  final String title;

  /// Countdown length when [BenchDurations] has no override.
  final Duration defaultDuration;

  /// Plain-language instruction; the hand is prepended on screen.
  final String prompt;
}

/// One hand/segment pair, in the order the wizard runs them.
class BenchPoseSpec {
  const BenchPoseSpec(this.hand, this.segment);

  final int hand;
  final PoseSegment segment;
}

final List<BenchPoseSpec> benchPoseSequence = [
  for (final hand in const [0, 1])
    for (final segment in PoseSegment.values) BenchPoseSpec(hand, segment),
];

/// Whether the active tracking source can feed the pose recorder.
class BenchPoseAvailability {
  const BenchPoseAvailability.available(this.runtime)
    : available = true,
      reason = null;

  const BenchPoseAvailability.unavailable(this.reason)
    : available = false,
      runtime = null;

  final bool available;

  /// `androidXr`, `viture` or `xreal`, when [available].
  final String? runtime;

  /// Why the step is not offered; null when it is.
  final String? reason;

  /// The gate: only a running vendor source that reports hand joints.
  factory BenchPoseAvailability.fromSelection(
    DebugTrackingSelection selection,
  ) {
    const supported = {
      DebugTrackingSource.androidXr,
      DebugTrackingSource.viture,
      DebugTrackingSource.xreal,
    };
    if (!supported.contains(selection.choice)) {
      return const BenchPoseAvailability.unavailable(
        'unavailable: no 6DoF hand-tracking source',
      );
    }
    final source = selection.attachment.value?.source;
    if (source == null || !source.capabilities.hasHandTracking) {
      return const BenchPoseAvailability.unavailable(
        'unavailable: no 6DoF hand-tracking source',
      );
    }
    return BenchPoseAvailability.available(selection.choice.name);
  }
}

final benchPoseAvailabilityProvider = Provider<BenchPoseAvailability>((ref) {
  return BenchPoseAvailability.fromSelection(
    ref.watch(debugTrackingSourceProvider),
  );
});

/// What one recorded segment produced.
class PoseCaptureResult {
  const PoseCaptureResult({
    required this.runtime,
    required this.path,
    required this.samples,
    required this.seconds,
  });

  final String runtime;
  final String path;
  final int samples;
  final int seconds;
}

/// Thrown when the tester skips a segment while it is recording.
class PoseSegmentCancelled implements Exception {
  const PoseSegmentCancelled();

  @override
  String toString() => 'skipped by tester';
}

/// The recorder seam: the wizard talks to this, tests replace it.
abstract interface class BenchPoseRecorder {
  String get runtime;

  /// Records one segment. Completing [cancel] stops the recording early; the
  /// caller then gets a [PoseSegmentCancelled] and nothing is saved.
  Future<PoseCaptureResult> record({
    required int hand,
    required PoseSegment segment,
    required Duration duration,
    Future<void>? cancel,
  });
}

/// Records through the debug screen's pose path: the same
/// [debugPosesProvider] samples, [PoseRecordingBuilder] and
/// [PoseRecordingStore] the debug panel uses.
class RealBenchPoseRecorder implements BenchPoseRecorder {
  RealBenchPoseRecorder({
    required this.ref,
    required this.store,
    required this.runtime,
  });

  final Ref ref;
  final PoseRecordingStore store;

  @override
  final String runtime;

  @override
  Future<PoseCaptureResult> record({
    required int hand,
    required PoseSegment segment,
    required Duration duration,
    Future<void>? cancel,
  }) async {
    final selection = ref.read(debugTrackingSourceProvider);
    final source = selection.attachment.value?.source;
    if (source == null || !source.capabilities.hasHandTracking) {
      throw StateError('unavailable: no 6DoF hand-tracking source');
    }

    final poses = ref.read(debugPosesProvider(DebugSource.real));
    final builder = PoseRecordingBuilder();
    _capture(builder, poses.value);
    final sub = ref.listen<AsyncValue<DebugPoses>>(
      debugPosesProvider(DebugSource.real),
      (_, next) => _capture(builder, next.value),
    );
    var aborted = false;
    try {
      final stop = Completer<void>();
      cancel?.then((_) {
        if (!stop.isCompleted) stop.complete();
      });
      await Future.any([Future<void>.delayed(duration), stop.future]);
      aborted = cancel != null && stop.isCompleted;
    } finally {
      sub.close();
    }
    if (aborted) throw const PoseSegmentCancelled();

    final recording = builder.build();
    if (recording.isEmpty) {
      throw StateError(
        'No pose samples arrived for ${_handName(hand)} ${segment.id}.',
      );
    }
    final name =
        'pose_capture_${runtime}_${_handName(hand).toLowerCase()}_'
        '${segment.id}.json';
    final file = await store.save(recording, DateTime.now(), name: name);
    return PoseCaptureResult(
      runtime: runtime,
      path: file.path,
      samples: recording.samples.length,
      seconds: duration.inSeconds,
    );
  }

  void _capture(PoseRecordingBuilder builder, DebugPoses? poses) {
    if (poses == null || poses.replayed) return;
    final time =
        poses.left?.hostTimeNs ??
        poses.right?.hostTimeNs ??
        poses.tracking?.hostTimeNs;
    if (time == null) return;
    builder.add(
      hostTimeNs: time,
      left: poses.left,
      right: poses.right,
      tracking: poses.tracking,
    );
  }

  static String _handName(int hand) => hand == 0 ? 'LEFT' : 'RIGHT';
}
