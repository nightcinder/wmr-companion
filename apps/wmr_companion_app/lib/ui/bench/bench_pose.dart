import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../../services/test_bundle.dart';
import '../debug/debug_providers.dart';
import '../debug/pose_recording_store.dart';

/// One guided 6DoF pose segment, from `filter-spec` rev 4 section 8.
///
/// The five corpus classes are the scored rows (still, drifting, slow, medium,
/// fast). [occlusion] is the diagnostic row section 8 also asks for; it has no
/// acceptance bar, so it is recorded once per hand outside the 4x5x2 corpus.
enum PoseSegment {
  still(
    'still',
    'Hold still',
    Duration(seconds: 10),
    'Rest the controller in your hand and brace your arm. Keep it still; the '
        'run repeats this hold until the timer ends.',
  ),
  drifting(
    'drifting',
    'Held, drifting',
    Duration(seconds: 10),
    'Hold as if you were aiming, and let the controller wander slowly; the '
        'run repeats this until the timer ends.',
  ),
  slowPan(
    'slow_pan',
    'Slow pan',
    Duration(seconds: 18),
    'Move 30 cm sideways over 3 s, then back. Repeat until the timer ends.',
  ),
  mediumPan(
    'medium_pan',
    'Medium pan',
    Duration(seconds: 10),
    'Move 50 cm sideways in 1 s, then back. Keep repeating until the timer '
        'ends.',
  ),
  fastFlick(
    'fast_flick',
    'Fast flick',
    Duration(seconds: 20),
    'Flick 45 cm in 0.3 s, pause, then bring it back. Repeat until the timer '
        'ends.',
  ),
  occlusion(
    'occlusion',
    'Occlusion (diagnostic)',
    Duration(seconds: 30),
    'Move as if aiming. Hide the hand from the sensors for a second or two, '
        'bring it back, and repeat. This run only measures reacquisition gaps; '
        'it has no acceptance bar.',
  );

  const PoseSegment(this.id, this.title, this.defaultDuration, this.prompt);

  /// Manifest and file-name key.
  final String id;

  /// Short title for the step screen.
  final String title;

  /// One cycle of the path, or the whole diagnostic run for [occlusion].
  ///
  /// The run itself repeats this cycle until the plan's minimum run duration is
  /// reached; see [BenchPosePlan.cyclesFor].
  final Duration defaultDuration;

  /// Plain-language instruction; the hand is prepended on screen.
  final String prompt;

  bool get isDiagnostic => this == occlusion;
}

/// The five motion classes the tuner scores. Occlusion is diagnostic only.
const List<PoseSegment> poseCorpus = [
  PoseSegment.still,
  PoseSegment.drifting,
  PoseSegment.slowPan,
  PoseSegment.mediumPan,
  PoseSegment.fastFlick,
];

/// One hand/segment/run cell, in the order the wizard runs them.
class BenchPoseSpec {
  const BenchPoseSpec(this.hand, this.segment, {this.run = 1});

  final int hand;
  final PoseSegment segment;

  /// Run index within this hand/class, starting at 1.
  final int run;

  bool get diagnostic => segment.isDiagnostic;

  /// Stable identity for resume progress and tests.
  String get key => '$hand:${segment.id}:$run';

  String get handName => hand == 0 ? 'LEFT' : 'RIGHT';
}

/// How much of the filter-spec section 8 corpus one guided run records.
///
/// The counts and the 30 s minimum are runtime parameters, not constants in
/// the recorder: tests override the provider with a shorter plan and the app
/// keeps the sheet's four runs per class.
class BenchPosePlan {
  const BenchPosePlan({
    this.runsPerClass = 4,
    this.minRunDuration = const Duration(seconds: 30),
    this.occlusionRuns = 1,
  });

  /// Section 8: "at least four runs per motion class per runtime".
  final int runsPerClass;

  /// Section 8: "each at least 30 s".
  final Duration minRunDuration;

  /// One diagnostic occlusion run per hand; section 8 gives it no bar.
  final int occlusionRuns;

  /// How many nominal cycles make a run at least [minRunDuration] long.
  int cyclesFor(PoseSegment segment) {
    final cycleUs = segment.defaultDuration.inMicroseconds;
    if (cycleUs <= 0) return 1;
    final cycles = (minRunDuration.inMicroseconds / cycleUs).ceil();
    return cycles < 1 ? 1 : cycles;
  }

  List<BenchPoseSpec> get sequence => [
    for (var hand = 0; hand < 2; hand++) ...[
      for (final segment in poseCorpus)
        for (var run = 1; run <= runsPerClass; run++)
          BenchPoseSpec(hand, segment, run: run),
      for (var run = 1; run <= occlusionRuns; run++)
        BenchPoseSpec(hand, PoseSegment.occlusion, run: run),
    ],
  ];

  /// Written into the resume file so a changed plan starts a fresh corpus.
  String get signature =>
      '${runsPerClass}x${poseCorpus.length}x2'
      '+${occlusionRuns}occlusion@${minRunDuration.inMilliseconds}ms';
}

final benchPosePlanProvider = Provider<BenchPosePlan>(
  (ref) => const BenchPosePlan(),
);

final benchPoseSequenceProvider = Provider<List<BenchPoseSpec>>(
  (ref) => ref.watch(benchPosePlanProvider).sequence,
);

/// The default 4x5x2 corpus plus the two diagnostic occlusion runs.
final List<BenchPoseSpec> benchPoseSequence = const BenchPosePlan().sequence;

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

/// What one recorded run produced.
class PoseCaptureResult {
  const PoseCaptureResult({
    required this.runtime,
    required this.path,
    required this.samples,
    required this.seconds,
    required this.run,
    required this.anchorRateHz,
    required this.provenance,
    this.diagnostics = const {},
  });

  final String runtime;
  final String path;
  final int samples;
  final int seconds;
  final int run;

  /// Measured rate of unique anchor samples in the file, or null for a single
  /// sample.
  final double? anchorRateHz;

  final Map<String, Object?> provenance;

  /// Occlusion-only counters: gaps in the hand anchor and the worst one.
  final Map<String, Object?> diagnostics;
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

  /// Records one run. Completing [cancel] stops the recording early; the
  /// caller then gets a [PoseSegmentCancelled] and nothing is saved.
  Future<PoseCaptureResult> record({
    required int hand,
    required PoseSegment segment,
    required Duration duration,
    int run = 1,
    Future<void>? cancel,
  });
}

/// Records the tracking source's own frames, one sample per new anchor, so a
/// corpus file is sampled at the anchor rate rather than the 30 Hz viewer tick.
class RealBenchPoseRecorder implements BenchPoseRecorder {
  RealBenchPoseRecorder({
    required this.ref,
    required this.store,
    required this.runtime,
    this.appCommit = 'unknown',
    this.firmwareSha,
  });

  final Ref ref;
  final PoseRecordingStore store;

  @override
  final String runtime;

  /// The app build that recorded the corpus file.
  final String appCommit;

  /// The firmware short SHA, when a bridge was attached.
  final String? firmwareSha;

  @override
  Future<PoseCaptureResult> record({
    required int hand,
    required PoseSegment segment,
    required Duration duration,
    int run = 1,
    Future<void>? cancel,
  }) async {
    final selection = ref.read(debugTrackingSourceProvider);
    final source = selection.attachment.value?.source;
    if (source == null || !source.capabilities.hasHandTracking) {
      throw StateError('unavailable: no 6DoF hand-tracking source');
    }

    final builder = PoseRecordingBuilder();
    var lastNs = -1;
    bool? wasPresent;
    int? absentSinceUs;
    var gapCount = 0;
    var occludedSamples = 0;
    var maxGapUs = 0;

    void capture(TrackingFrame frame) {
      final time = frame.fusionTimeNs;
      if (time <= lastNs) return;
      lastNs = time;

      // Occlusion diagnostics: a gap starts when a previously tracked anchor
      // disappears and ends when it comes back. Section 8 has no bar for it.
      final present = _anchorPresent(frame, hand);
      final timeUs = time ~/ 1000;
      if (present) {
        if (wasPresent == false && absentSinceUs != null) {
          gapCount++;
          final gapUs = timeUs - absentSinceUs!;
          if (gapUs > maxGapUs) maxGapUs = gapUs;
        }
        wasPresent = true;
        absentSinceUs = null;
      } else {
        occludedSamples++;
        if (wasPresent == true) absentSinceUs = timeUs;
        wasPresent = false;
      }

      builder.add(hostTimeNs: time, tracking: frame);
    }

    final sub = source.frames.listen(capture);
    var aborted = false;
    try {
      final stop = Completer<void>();
      cancel?.then((_) {
        if (!stop.isCompleted) stop.complete();
      });
      await Future.any([Future<void>.delayed(duration), stop.future]);
      aborted = cancel != null && stop.isCompleted;
    } finally {
      await sub.cancel();
    }
    if (aborted) throw const PoseSegmentCancelled();

    final samples = builder.length;
    if (samples == 0) {
      throw StateError(
        'No pose samples arrived for ${_handName(hand)} ${segment.id}.',
      );
    }

    final spanUs = builder.span.inMicroseconds;
    final rate = samples < 2 || spanUs <= 0
        ? null
        : (samples - 1) * Duration.microsecondsPerSecond / spanUs;
    final diagnostics = <String, Object?>{
      'occlusion_gaps': gapCount,
      'occluded_samples': occludedSamples,
      'max_occlusion_ms': maxGapUs == 0 ? null : (maxGapUs / 1000).round(),
    };
    final provenance = <String, Object?>{
      'kind': 'hardware',
      'runtime': runtime,
      'app_commit': appCommit,
      'firmware_sha': firmwareSha,
      'anchor_rate_hz': rate,
      'run_index': run,
      'hand': _handName(hand),
      'motion': segment.id,
      'seconds': duration.inSeconds,
      if (segment.isDiagnostic) 'diagnostics': diagnostics,
    };
    final recording = builder.build(provenance: provenance);
    final file = await store.save(
      recording,
      DateTime.now(),
      name: poseCaptureFileName(
        runtime: runtime,
        hand: _handName(hand).toLowerCase(),
        segment: segment.id,
        run: run,
      ),
    );
    return PoseCaptureResult(
      runtime: runtime,
      path: file.path,
      samples: samples,
      seconds: duration.inSeconds,
      run: run,
      anchorRateHz: rate,
      provenance: provenance,
      diagnostics: diagnostics,
    );
  }

  static bool _anchorPresent(TrackingFrame frame, int hand) {
    final tracked = hand == 0 ? TrackedHand.left : TrackedHand.right;
    final controller = frame.controller(tracked);
    if (controller != null && controller.isTracked) return true;
    final anchor = frame.hand(tracked)?.controllerAnchor;
    return anchor != null && anchor.isTracked;
  }

  static String _handName(int hand) => hand == 0 ? 'LEFT' : 'RIGHT';
}
