import 'dart:math' as math;

/// Estimates the gyro bias (sensor axes, rad/s) from the first stationary
/// second.
///
/// A candidate window collects [window] seconds of samples (the sum of their
/// dt, which comes from the device ticks). It is accepted when the gyro mean
/// is small ([maxMeanRate]) and the gyro and accel-magnitude spread are low
/// ([maxGyroStd], [maxAccelStd]); otherwise it restarts from the next sample.
/// A step longer than [maxStep] (a gap) also restarts it. Once accepted the
/// bias holds until [restart].
///
/// The thresholds are guesses from the firmware docs (stationary gyro noise
/// about 0.016 rad/s, accel magnitude about 10.0 with no motion). Not tuned on
/// hardware.
class GyroBiasEstimator {
  GyroBiasEstimator({
    this.window = 1.0,
    this.maxMeanRate = 0.25,
    this.maxGyroStd = 0.05,
    this.maxAccelStd = 0.25,
    this.maxStep = 0.1,
  });

  final double window;
  final double maxMeanRate;
  final double maxGyroStd;
  final double maxAccelStd;
  final double maxStep;

  List<double> _bias = const [0, 0, 0];
  bool _calibrated = false;
  int _attempts = 0;

  // Window accumulators (Welford).
  int _n = 0;
  double _elapsed = 0;
  final List<double> _mean = [0, 0, 0];
  final List<double> _m2 = [0, 0, 0];
  double _aMean = 0;
  double _aM2 = 0;

  /// Bias to subtract from the gyro, sensor axes. Zero until [calibrated].
  List<double> get bias => _bias;
  bool get calibrated => _calibrated;

  /// Rejected windows since the last [restart].
  int get rejectedWindows => _attempts;

  /// Fraction of the current window collected, 0..1; 1 when calibrated.
  double get progress => _calibrated ? 1 : math.min(1, _elapsed / window);

  /// Forgets the bias and starts looking for a stationary window again.
  void restart() {
    _bias = const [0, 0, 0];
    _calibrated = false;
    _attempts = 0;
    _clearWindow();
  }

  /// Drops the current window, e.g. after a discontinuity. Keeps a finished
  /// bias.
  void breakWindow() => _clearWindow();

  void _clearWindow() {
    _n = 0;
    _elapsed = 0;
    for (var i = 0; i < 3; i++) {
      _mean[i] = 0;
      _m2[i] = 0;
    }
    _aMean = 0;
    _aM2 = 0;
  }

  /// Feeds one sample ([dt] is the step since the previous sample, seconds).
  /// Returns true on the sample that completes the calibration.
  bool add(List<double> gyro, List<double> accel, double dt) {
    if (_calibrated) return false;
    if (!(dt > 0) || dt > maxStep) {
      _clearWindow();
      return false;
    }
    final aNorm = math.sqrt(
      accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2],
    );
    if (!aNorm.isFinite || gyro.any((g) => !g.isFinite)) {
      _clearWindow();
      return false;
    }
    _n++;
    _elapsed += dt;
    for (var i = 0; i < 3; i++) {
      final d = gyro[i] - _mean[i];
      _mean[i] += d / _n;
      _m2[i] += d * (gyro[i] - _mean[i]);
    }
    final da = aNorm - _aMean;
    _aMean += da / _n;
    _aM2 += da * (aNorm - _aMean);

    if (_elapsed < window) return false;
    final stationary = _isStationary();
    if (stationary) {
      _bias = List.unmodifiable(_mean);
      _calibrated = true;
      _clearWindow();
      return true;
    }
    _attempts++;
    _clearWindow();
    return false;
  }

  bool _isStationary() {
    if (_n < 2) return false;
    for (var i = 0; i < 3; i++) {
      if (_mean[i].abs() > maxMeanRate) return false;
      if (math.sqrt(_m2[i] / (_n - 1)) > maxGyroStd) return false;
    }
    return math.sqrt(_aM2 / (_n - 1)) <= maxAccelStd;
  }
}
