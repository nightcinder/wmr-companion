import 'package:vector_math/vector_math_64.dart';

import 'pose_recording.dart';
import 'tracking_types.dart';

/// The speed regime a guided pose-capture cell is expected to follow.
///
/// `filter-spec` rev 4 section 8 gives the still cell a 0 cm/s nominal and
/// each moving class a nominal speed; the tuner scores only samples within
/// +/-25% of that nominal. The occlusion diagnostic has no acceptance bar and
/// is not gated.
enum SpeedGateCell {
  /// Segment S: the hand rests, so the median speed must be under 2 cm/s.
  ///
  /// The pose-filter tuner drops the first 2 s of a still capture, so the gate
  /// uses the same settle window.
  still(minSpeedMps: 0, maxSpeedMps: 0.02, warmup: Duration(seconds: 2)),

  /// Segment D: held, drifting at the 10-50 cm/s band section 8 names.
  drifting(minSpeedMps: 0.10, maxSpeedMps: 0.50),

  /// Slow pan: section 8's 10 cm/s nominal, +/-25%.
  slowPan(minSpeedMps: 0.075, maxSpeedMps: 0.125),

  /// Medium pan: section 8's 50 cm/s nominal, +/-25%.
  mediumPan(minSpeedMps: 0.375, maxSpeedMps: 0.625),

  /// Fast flick: section 8's 150 cm/s nominal, +/-25%.
  fastFlick(minSpeedMps: 1.125, maxSpeedMps: 1.875);

  const SpeedGateCell({
    required this.minSpeedMps,
    required this.maxSpeedMps,
    this.warmup = const Duration(seconds: 1),
  });

  /// Inclusive lower bound. Still cells accept zero.
  final double minSpeedMps;

  /// Inclusive upper bound.
  final double maxSpeedMps;

  /// Leading time excluded before scoring.
  ///
  /// One second matches the tuner's general `_warmup`; the still cell uses the
  /// tuner's 2 s settle rather than scoring seconds 1-2.
  final Duration warmup;

  bool contains(double speedMps) =>
      speedMps >= minSpeedMps - _bandEpsilon &&
      speedMps <= maxSpeedMps + _bandEpsilon;

  /// Human-readable band for the bundle manifest.
  String get bandLabel => this == still
      ? '< ${_cm(maxSpeedMps)} cm/s'
      : '${_cm(minSpeedMps)}-${_cm(maxSpeedMps)} cm/s';

  static String _cm(double mps) {
    final cm = mps * 100;
    return cm == cm.roundToDouble()
        ? cm.toStringAsFixed(0)
        : cm.toStringAsFixed(1);
  }
}

/// Pass or warning for one pose-capture cell.
enum SpeedGateStatus { pass, warning }

/// Absorbs the last bits of a float division at an inclusive band edge, so a
/// trajectory commanded at exactly 2, 10 or 50 cm/s is not warned.
const double _bandEpsilon = 1e-6;

/// One position sample on the recording's host clock.
class SpeedGateSample {
  const SpeedGateSample({required this.timeNs, required this.position});

  final int timeNs;
  final Vector3 position;
}

/// The speed gate's verdict for one pose-capture cell.
class SpeedGateResult {
  const SpeedGateResult({
    required this.cell,
    required this.status,
    required this.sampleCount,
    required this.gatedSamples,
    required this.inBandSamples,
    required this.medianSpeedMps,
    required this.reason,
  });

  final SpeedGateCell cell;
  final SpeedGateStatus status;

  /// Samples in the recording, before the warm-up gate.
  final int sampleCount;

  /// Samples the speed window could score after the warm-up.
  final int gatedSamples;

  /// Gated samples inside [SpeedGateCell.minSpeedMps]..[SpeedGateCell.maxSpeedMps].
  final int inBandSamples;

  /// Median speed of the gated samples, or null when there were too few.
  final double? medianSpeedMps;

  /// One sentence naming the measured speed and the expected band.
  final String reason;

  bool get passed => status == SpeedGateStatus.pass;

  double? get inBandFraction =>
      gatedSamples == 0 ? null : inBandSamples / gatedSamples;

  Map<String, Object?> toJson() => {
    'cell': cell.name,
    'status': status.name,
    'samples': sampleCount,
    'gated_samples': gatedSamples,
    'in_band_samples': inBandSamples,
    'in_band_fraction': _round(inBandFraction),
    'median_speed_mps': _round(medianSpeedMps),
    'band_min_mps': cell.minSpeedMps,
    'band_max_mps': cell.maxSpeedMps,
    'reason': reason,
  };

  static double? _round(double? value) {
    if (value == null || !value.isFinite) return null;
    return double.parse(value.toStringAsFixed(4));
  }
}

/// Measures a cell's linear speed against the section 8 bands.
///
/// Speed is measured over a centred window, the same way the pose-filter
/// tuner gates samples, so a validated cell is scorable by that tuner. The
/// verdict uses the median gated speed rather than a single peak: tracking
/// jitter produces isolated spikes, while the cell's motion is what the
/// tester was asked to perform.
class SpeedGateEvaluator {
  const SpeedGateEvaluator({
    this.warmup,
    this.window = const Duration(milliseconds: 500),
    this.minSamples = 3,
  });

  /// Leading time override; null uses the cell's own [SpeedGateCell.warmup].
  final Duration? warmup;

  /// Centred window used for each instantaneous speed.
  final Duration window;

  /// Fewer gated samples than this cannot support a verdict.
  final int minSamples;

  /// Evaluates a position trace for [cell].
  SpeedGateResult evaluate(
    List<SpeedGateSample> samples, {
    required SpeedGateCell cell,
  }) {
    final sorted = [
      for (final sample in samples)
        if (_finite(sample.position)) sample,
    ]..sort((a, b) => a.timeNs.compareTo(b.timeNs));
    if (sorted.isEmpty) {
      return SpeedGateResult(
        cell: cell,
        status: SpeedGateStatus.warning,
        sampleCount: 0,
        gatedSamples: 0,
        inBandSamples: 0,
        medianSpeedMps: null,
        reason: 'no positions to score; expected ${cell.bandLabel}',
      );
    }

    final effectiveWarmup = warmup ?? cell.warmup;
    final originNs = sorted.first.timeNs;
    final startNs = originNs + effectiveWarmup.inMicroseconds * 1000;
    final halfWindowNs = window.inMicroseconds * 1000 ~/ 2;
    final speeds = <double>[];
    var left = 0;
    var right = 0;
    for (var i = 0; i < sorted.length; i++) {
      final time = sorted[i].timeNs;
      final low = time - halfWindowNs;
      final high = time + halfWindowNs;
      while (left < i && sorted[left].timeNs < low) {
        left++;
      }
      if (right < i) right = i;
      while (right + 1 < sorted.length && sorted[right + 1].timeNs <= high) {
        right++;
      }
      if (time < startNs) continue;
      final spanNs = sorted[right].timeNs - sorted[left].timeNs;
      if (spanNs <= 0) continue;
      final speedMps =
          (sorted[right].position - sorted[left].position).length /
          (spanNs / 1000000000);
      if (speedMps.isFinite) speeds.add(speedMps);
    }

    if (speeds.length < minSamples) {
      return SpeedGateResult(
        cell: cell,
        status: SpeedGateStatus.warning,
        sampleCount: sorted.length,
        gatedSamples: speeds.length,
        inBandSamples: 0,
        medianSpeedMps: null,
        reason:
            '${speeds.length} samples after the '
            '${effectiveWarmup.inMilliseconds} ms warm-up; need $minSamples; '
            'expected ${cell.bandLabel}',
      );
    }

    speeds.sort();
    final middle = speeds.length ~/ 2;
    final median = speeds.length.isOdd
        ? speeds[middle]
        : (speeds[middle - 1] + speeds[middle]) / 2;
    final inBand = speeds.where(cell.contains).length;
    final passed = cell.contains(median);
    final measured = (median * 100).toStringAsFixed(1);
    final reason = passed
        ? '$measured cm/s is in ${cell.bandLabel}'
        : median < cell.minSpeedMps
        ? '$measured cm/s is below ${cell.bandLabel}'
        : '$measured cm/s is above ${cell.bandLabel}';
    return SpeedGateResult(
      cell: cell,
      status: passed ? SpeedGateStatus.pass : SpeedGateStatus.warning,
      sampleCount: sorted.length,
      gatedSamples: speeds.length,
      inBandSamples: inBand,
      medianSpeedMps: median,
      reason: reason,
    );
  }

  /// Evaluates one hand from a guided-bench recording.
  ///
  /// A runtime-tracked controller pose wins; otherwise the hand's controller
  /// anchor is used, which is the same signal `PoseCapture.fromRecording`
  /// feeds the filter tuner. Duplicate tracking frames are collapsed.
  SpeedGateResult evaluateRecording(
    PoseRecording recording, {
    required TrackedHand hand,
    required SpeedGateCell cell,
  }) => evaluate(samplesFromRecording(recording, hand: hand), cell: cell);

  /// Extracts the position trace for [hand] from a recording.
  static List<SpeedGateSample> samplesFromRecording(
    PoseRecording recording, {
    required TrackedHand hand,
  }) {
    final samples = <SpeedGateSample>[];
    int? lastFrameTime;
    for (final sample in recording.samples) {
      final frame = sample.tracking;
      if (frame != null) {
        final controller = frame.controller(hand);
        final anchor = frame.hand(hand)?.controllerAnchor;
        final Vector3? position;
        if (controller != null && controller.isTracked) {
          position = controller.pose.translation;
        } else if (anchor != null && anchor.isTracked) {
          position = anchor.pose.translation;
        } else {
          position = null;
        }
        if (position == null) continue;
        final time = frame.fusionTimeNs;
        if (lastFrameTime == time) continue;
        lastFrameTime = time;
        if (!_finite(position)) continue;
        samples.add(
          SpeedGateSample(timeNs: time, position: Vector3.copy(position)),
        );
        continue;
      }
      final pose = hand == TrackedHand.left ? sample.left : sample.right;
      final position = pose?.position;
      if (position == null || !_finite(position)) continue;
      samples.add(
        SpeedGateSample(
          timeNs: sample.hostTimeNs,
          position: Vector3.copy(position),
        ),
      );
    }
    return samples;
  }

  static bool _finite(Vector3 position) =>
      position.x.isFinite && position.y.isFinite && position.z.isFinite;
}
