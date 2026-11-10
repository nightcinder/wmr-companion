import 'package:vector_math/vector_math_64.dart';

import 'pose_recording.dart';
import 'tracking_types.dart';

/// How a cell's verdict is measured.
enum SpeedGateMetric {
  /// Continuous motion: the median gated speed must be in band.
  median,

  /// Intermittent motion: the fastest short-window speed must be in band.
  ///
  /// A fast flick is 45 cm in 0.3 s followed by a pause and the return, so
  /// most samples sit at rest. A median over the whole cell would report the
  /// pauses rather than the flick.
  peak,
}

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
  ///
  /// The instructed flick is 45 cm in 0.3 s, so the measurement window is no
  /// longer than the flick; a 0.5 s window spans the whole leg plus the pause
  /// and can never measure 150 cm/s. The verdict uses the peak short-window
  /// speed because the flick is intermittent, not sustained.
  fastFlick(
    minSpeedMps: 1.125,
    maxSpeedMps: 1.875,
    window: Duration(milliseconds: 300),
    metric: SpeedGateMetric.peak,
  );

  const SpeedGateCell({
    required this.minSpeedMps,
    required this.maxSpeedMps,
    this.warmup = const Duration(seconds: 1),
    this.window = const Duration(milliseconds: 500),
    this.metric = SpeedGateMetric.median,
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

  /// Centred window used for each instantaneous speed.
  ///
  /// The 0.5 s default matches the tuner's `_speedsCmS`; the fast flick uses
  /// its own 0.3 s so the window fits inside one flick.
  final Duration window;

  /// Statistic the verdict uses.
  final SpeedGateMetric metric;

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
    required this.peakSpeedMps,
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

  /// Fastest gated sample, or null when there were too few.
  ///
  /// This is the fastest speed measured over [SpeedGateCell.window] (0.3 s for
  /// the fast flick), not a single-frame difference.
  final double? peakSpeedMps;

  /// The speed the verdict used: [medianSpeedMps] or [peakSpeedMps] per
  /// [SpeedGateCell.metric].
  double? get measuredSpeedMps =>
      cell.metric == SpeedGateMetric.peak ? peakSpeedMps : medianSpeedMps;

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
    'peak_speed_mps': _round(peakSpeedMps),
    'speed_metric': cell.metric.name,
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
/// default window is 0.5 s, matching the tuner; the fast flick uses a 0.3 s
/// window because the instructed flick is only 0.3 s long.
///
/// Continuous cells use the median gated speed rather than a single peak:
/// tracking jitter produces isolated spikes, while the cell's motion is what
/// the tester was asked to perform. The fast flick is intermittent, so its
/// verdict uses the peak short-window speed instead.
class SpeedGateEvaluator {
  const SpeedGateEvaluator({this.warmup, this.window, this.minSamples = 3});

  /// Leading time override; null uses the cell's own [SpeedGateCell.warmup].
  final Duration? warmup;

  /// Window override; null uses the cell's own [SpeedGateCell.window].
  final Duration? window;

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
        peakSpeedMps: null,
        reason: 'no positions to score; expected ${cell.bandLabel}',
      );
    }

    final effectiveWarmup = warmup ?? cell.warmup;
    final effectiveWindow = window ?? cell.window;
    final originNs = sorted.first.timeNs;
    final startNs = originNs + effectiveWarmup.inMicroseconds * 1000;
    final halfWindowNs = effectiveWindow.inMicroseconds * 1000 ~/ 2;
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
        peakSpeedMps: null,
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
    final peak = speeds.last;
    final inBand = speeds.where(cell.contains).length;
    final measured = cell.metric == SpeedGateMetric.peak ? peak : median;
    final passed = cell.contains(measured);
    final measuredCm = (measured * 100).toStringAsFixed(1);
    final label = cell.metric == SpeedGateMetric.peak ? 'peak ' : '';
    final reason = passed
        ? '$label$measuredCm cm/s is in ${cell.bandLabel}'
        : measured < cell.minSpeedMps
        ? '$label$measuredCm cm/s is below ${cell.bandLabel}'
        : '$label$measuredCm cm/s is above ${cell.bandLabel}';
    return SpeedGateResult(
      cell: cell,
      status: passed ? SpeedGateStatus.pass : SpeedGateStatus.warning,
      sampleCount: sorted.length,
      gatedSamples: speeds.length,
      inBandSamples: inBand,
      medianSpeedMps: median,
      peakSpeedMps: peak,
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

/// The tester-facing state of a live speed check.
enum SpeedGateLiveStatus {
  /// No position sample has arrived yet.
  waiting,

  /// The cell's settle/warm-up window is still running, so nothing is scored.
  settling,

  /// The recent measured speed is inside the cell's band.
  inBand,

  /// The recent measured speed is below the cell's band.
  tooSlow,

  /// The recent measured speed is above the cell's band.
  tooFast,
}

/// One live speed reading for the guided-bench HUD.
class SpeedGateLiveFeedback {
  const SpeedGateLiveFeedback({
    required this.cell,
    required this.status,
    required this.speedMps,
    required this.samples,
  });

  final SpeedGateCell cell;
  final SpeedGateLiveStatus status;

  /// Recent measured speed, or null before the warm-up has a reading.
  final double? speedMps;

  /// Position samples currently inside the live speed window.
  final int samples;

  bool get inBand => status == SpeedGateLiveStatus.inBand;

  /// Short instruction for the tester.
  String get statusLabel => switch (status) {
    SpeedGateLiveStatus.waiting => 'waiting for hand',
    SpeedGateLiveStatus.settling => 'settling',
    SpeedGateLiveStatus.inBand => 'in range',
    SpeedGateLiveStatus.tooSlow => 'too slow',
    SpeedGateLiveStatus.tooFast => 'too fast',
  };

  /// Measured speed plus [statusLabel], for the hand label in the HUD.
  String get speedLabel {
    final speed = speedMps;
    if (speed == null) return statusLabel;
    return '${(speed * 100).toStringAsFixed(1)} cm/s · $statusLabel';
  }
}

/// Live per-frame speed feedback for one guided capture cell.
///
/// The final verdict is computed over the whole recording by
/// [SpeedGateEvaluator]. This tracker uses the same band, warm-up and window on
/// the samples seen so far, so the hand colour points at the signal that will
/// be scored. Live frames have no future samples, so the speed window trails
/// instead of centring; the recent speeds are then reduced with the cell's own
/// metric (median for continuous motion, peak for the flick). That keeps a
/// single jitter spike from painting the hand red during a still hold while
/// still showing the flick's peak.
class SpeedGateLiveTracker {
  SpeedGateLiveTracker({
    required this.cell,
    this.minSamples = 3,
    this.smoothingWindow = const Duration(seconds: 1),
  }) : _feedback = SpeedGateLiveFeedback(
         cell: cell,
         status: SpeedGateLiveStatus.waiting,
         speedMps: null,
         samples: 0,
       );

  final SpeedGateCell cell;

  /// Recent readings needed before a verdict is shown.
  final int minSamples;

  /// How much recent history the median/peak is taken over.
  final Duration smoothingWindow;

  final List<SpeedGateSample> _window = [];
  final List<(int, double)> _speeds = [];
  int? _originNs;
  SpeedGateLiveFeedback _feedback;

  /// Latest reading; [SpeedGateLiveStatus.waiting] before any sample.
  SpeedGateLiveFeedback get feedback => _feedback;

  /// Clears the tracker for a new capture segment.
  void reset() {
    _window.clear();
    _speeds.clear();
    _originNs = null;
    _feedback = SpeedGateLiveFeedback(
      cell: cell,
      status: SpeedGateLiveStatus.waiting,
      speedMps: null,
      samples: 0,
    );
  }

  /// Feeds the same hand position [SpeedGateEvaluator.samplesFromRecording]
  /// scores: a tracked controller pose first, then the hand controller anchor.
  SpeedGateLiveFeedback addFrame(
    TrackingFrame frame, {
    required TrackedHand hand,
  }) {
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
    if (position == null || !SpeedGateEvaluator._finite(position)) {
      return _feedback;
    }
    return addSample(timeNs: frame.fusionTimeNs, position: position);
  }

  /// Adds one position sample and returns the updated feedback.
  SpeedGateLiveFeedback addSample({
    required int timeNs,
    required Vector3 position,
  }) {
    if (!SpeedGateEvaluator._finite(position)) return _feedback;
    if (_window.isNotEmpty && timeNs <= _window.last.timeNs) return _feedback;
    _originNs ??= timeNs;
    _window.add(
      SpeedGateSample(timeNs: timeNs, position: Vector3.copy(position)),
    );

    // Keep the newest sample at or before the window edge as the far end, so
    // the measured span is the cell's window even at a high frame rate.
    final windowCutoffNs = timeNs - cell.window.inMicroseconds * 1000;
    while (_window.length > 1 && _window[1].timeNs <= windowCutoffNs) {
      _window.removeAt(0);
    }

    final elapsedNs = timeNs - _originNs!;
    if (elapsedNs < cell.warmup.inMicroseconds * 1000) {
      _feedback = SpeedGateLiveFeedback(
        cell: cell,
        status: SpeedGateLiveStatus.settling,
        speedMps: null,
        samples: _window.length,
      );
      return _feedback;
    }

    final first = _window.first;
    final spanNs = timeNs - first.timeNs;
    final minimumSpanNs = cell.window.inMicroseconds * 1000 ~/ 2;
    if (spanNs < minimumSpanNs) {
      _feedback = SpeedGateLiveFeedback(
        cell: cell,
        status: SpeedGateLiveStatus.settling,
        speedMps: null,
        samples: _window.length,
      );
      return _feedback;
    }

    final speedMps = (position - first.position).length / (spanNs / 1000000000);
    if (!speedMps.isFinite) return _feedback;
    _speeds.add((timeNs, speedMps));
    final speedCutoffNs = timeNs - smoothingWindow.inMicroseconds * 1000;
    while (_speeds.isNotEmpty && _speeds.first.$1 < speedCutoffNs) {
      _speeds.removeAt(0);
    }
    if (_speeds.length < minSamples) {
      _feedback = SpeedGateLiveFeedback(
        cell: cell,
        status: SpeedGateLiveStatus.settling,
        speedMps: null,
        samples: _window.length,
      );
      return _feedback;
    }

    final recent = [for (final reading in _speeds) reading.$2]..sort();
    final measured = cell.metric == SpeedGateMetric.peak
        ? recent.last
        : _median(recent);
    final status = cell.contains(measured)
        ? SpeedGateLiveStatus.inBand
        : measured < cell.minSpeedMps
        ? SpeedGateLiveStatus.tooSlow
        : SpeedGateLiveStatus.tooFast;
    _feedback = SpeedGateLiveFeedback(
      cell: cell,
      status: status,
      speedMps: measured,
      samples: _window.length,
    );
    return _feedback;
  }

  static double _median(List<double> sorted) {
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}
