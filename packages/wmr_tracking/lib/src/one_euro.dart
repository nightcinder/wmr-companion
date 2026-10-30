import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// A timestamp-aware One Euro filter for 3D positions.
///
/// This is the shared filter used by [SixDofFuser] for the fused controller
/// position when a tracking source provides a hand anchor. It follows the
/// One Euro paper: a low-pass filter whose cutoff rises with the estimated
/// speed, so slow movement is smoothed and fast movement keeps up.
///
/// The paper's `beta` is scale-dependent. [beta] here expects **centimetres
/// per second**, because the published defaults (`beta = 0.02`) assume
/// centimetre-scale input. Inputs and outputs are metres (the framework's
/// OpenXR unit); the conversion happens inside [filter]. Passing metre-scale
/// speed straight into the paper formula would make the cutoff almost
/// constant and add about 158 ms of lag.
///
/// The filter resets on the first sample, on a gap longer than [maxDt], and
/// whenever [reset] is called. It rejects non-finite positions and
/// non-positive timestamps with [ArgumentError] rather than poisoning the
/// output with NaN.
class OneEuroFilter {
  OneEuroFilter({
    this.minCutoffHz = defaultMinCutoffHz,
    this.beta = defaultBeta,
    this.dCutoffHz = defaultDCutoffHz,
    this.minDt = defaultMinDt,
    this.maxDt = defaultMaxDt,
  }) : assert(minCutoffHz > 0),
       assert(beta >= 0),
       assert(dCutoffHz > 0),
       assert(minDt.inMicroseconds > 0),
       assert(maxDt.inMicroseconds >= minDt.inMicroseconds);

  // ONY-502 keeps the published One Euro tuning until a hardware capture
  // exists. The grid tuner (`tool/pose_filter_tune.dart`) chooses minCutoff,
  // beta and dCutoff from recordings; they are not chosen by reasoning here.
  // `minDt` is structural: it follows the anchor rate (about 11 ms at 90 Hz),
  // not the 240 Hz IMU, so a faster controller tick cannot inflate the speed
  // estimate.
  static const double defaultMinCutoffHz = 1.0;
  static const double defaultBeta = 0.02;
  static const double defaultDCutoffHz = 1.0;
  static const Duration defaultMinDt = Duration(milliseconds: 11);
  static const Duration defaultMaxDt = Duration(milliseconds: 100);

  /// Cutoff at zero speed, in hertz.
  final double minCutoffHz;

  /// Speed coefficient, in hertz per centimetre per second.
  final double beta;

  /// Cutoff for the speed estimate, in hertz.
  final double dCutoffHz;

  /// Clamp for the sample interval. At 240 Hz a frame arrives every 4.167 ms.
  final Duration minDt;
  final Duration maxDt;

  Vector3? _value;
  Vector3? _derivative;
  int? _timeNs;

  /// Whether a sample has been accepted since the last reset.
  bool get hasValue => _value != null;

  /// The last filtered value in metres, or null.
  Vector3? get value => _value == null ? null : Vector3.copy(_value!);

  /// Filters [sample], a position in metres sampled at [timeNs] on a
  /// monotonic clock.
  Vector3 filter(Vector3 sample, int timeNs) {
    if (timeNs <= 0) {
      throw ArgumentError.value(
        timeNs,
        'timeNs',
        'must be a positive monotonic timestamp',
      );
    }
    if (!_isFinite(sample)) {
      throw ArgumentError.value(sample, 'sample', 'must be finite');
    }

    final previousTime = _timeNs;
    final previous = _value;
    if (previousTime == null || previous == null) {
      _timeNs = timeNs;
      _value = Vector3.copy(sample);
      _derivative = Vector3.zero();
      return Vector3.copy(sample);
    }

    final elapsedNs = timeNs - previousTime;
    if (elapsedNs <= 0) {
      // A duplicate or out-of-order timestamp cannot produce a derivative.
      // Keep the last state; fusion only asks for increasing sample times.
      return Vector3.copy(previous);
    }
    if (elapsedNs > maxDt.inMicroseconds * 1000) {
      reset();
      _timeNs = timeNs;
      _value = Vector3.copy(sample);
      _derivative = Vector3.zero();
      return Vector3.copy(sample);
    }

    var dt = elapsedNs / Duration.microsecondsPerSecond;
    dt = dt
        .clamp(
          minDt.inMicroseconds / Duration.microsecondsPerSecond,
          maxDt.inMicroseconds / Duration.microsecondsPerSecond,
        )
        .toDouble();

    // Work in centimetres so the paper's beta default applies to metres.
    const metresToCentimetres = 100.0;
    final scaled = sample * metresToCentimetres;
    final scaledPrevious = previous * metresToCentimetres;
    final rawDerivative = (scaled - scaledPrevious) / dt;
    final derivative = _lowPass(
      rawDerivative,
      _derivative! * metresToCentimetres,
      _alpha(dCutoffHz, dt),
    );
    final cutoff = minCutoffHz + beta * derivative.length;
    final filtered = _lowPass(scaled, scaledPrevious, _alpha(cutoff, dt));

    _timeNs = timeNs;
    _value = filtered / metresToCentimetres;
    _derivative = derivative / metresToCentimetres;
    return Vector3.copy(_value!);
  }

  /// Forgets the state. The next sample passes through unfiltered.
  void reset() {
    _value = null;
    _derivative = null;
    _timeNs = null;
  }

  static double _alpha(double cutoffHz, double dt) {
    final tau = 1 / (2 * math.pi * cutoffHz);
    return 1 / (1 + tau / dt);
  }

  static Vector3 _lowPass(Vector3 sample, Vector3 previous, double alpha) =>
      previous + (sample - previous) * alpha;

  static bool _isFinite(Vector3 value) =>
      value.x.isFinite && value.y.isFinite && value.z.isFinite;
}

/// Tuning for the hand-anchor [OneEuroFilter], selectable per runtime.
///
/// [SixDofFusionConfig.poseFilter] carries one of these into the fuser. The
/// no-argument values are the published defaults; the ONY-502 tuner replaces
/// them per runtime once hardware captures exist. They are deliberately not
/// chosen by reasoning.
class PoseFilterConfig {
  const PoseFilterConfig({
    this.minCutoffHz = OneEuroFilter.defaultMinCutoffHz,
    this.beta = OneEuroFilter.defaultBeta,
    this.dCutoffHz = OneEuroFilter.defaultDCutoffHz,
    this.minDt = OneEuroFilter.defaultMinDt,
    this.maxDt = OneEuroFilter.defaultMaxDt,
  }) : assert(minCutoffHz > 0),
       assert(beta >= 0),
       assert(dCutoffHz > 0);

  /// Cutoff at zero speed, in hertz.
  final double minCutoffHz;

  /// Speed coefficient, in hertz per centimetre per second.
  final double beta;

  /// Cutoff for the speed estimate, in hertz.
  final double dCutoffHz;

  /// Clamp for the anchor sample interval.
  final Duration minDt;
  final Duration maxDt;

  OneEuroFilter createFilter() => OneEuroFilter(
    minCutoffHz: minCutoffHz,
    beta: beta,
    dCutoffHz: dCutoffHz,
    minDt: minDt,
    maxDt: maxDt,
  );

  Map<String, Object?> toJson() => {
    'min_cutoff_hz': minCutoffHz,
    'beta': beta,
    'd_cutoff_hz': dCutoffHz,
    'min_dt_us': minDt.inMicroseconds,
    'max_dt_us': maxDt.inMicroseconds,
  };
}
