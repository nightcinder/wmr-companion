import '../protocol/decoded_record.dart';

enum TickStepKind {
  /// First sample of a hand (or the first after a discontinuity): baseline
  /// only, no dt.
  baseline,

  /// A normal step with a valid [TickStep.dtSeconds].
  step,

  /// Ticks and the ESP32 receive time disagree by more than the tolerance
  /// (controller timer restarted, or an ESP32 reboot): the caller should
  /// reset the filter. The sample becomes the new baseline.
  discontinuity,
}

class TickStep {
  const TickStep(this.kind, {this.dtTicks = 0, this.dtSeconds = 0});

  final TickStepKind kind;
  final int dtTicks;
  final double dtSeconds;
}

/// Percentiles of the dt values seen (seconds).
class DtStats {
  const DtStats({this.count = 0, this.p50 = 0, this.p95 = 0, this.max = 0});

  /// Samples in the window the percentiles come from.
  final int count;
  final double p50;
  final double p95;

  /// Largest dt since start (not just the window).
  final double max;
}

/// Turns the device tick counter of one hand into time steps.
///
/// - `dt` is `(ticks - previous) mod 2^32` at 100 ns per tick: correct across
///   a wrap, and a lost report just makes the next dt larger.
/// - The spec's discontinuity rule: `dt_ticks * 100 ns` against
///   `delta(rx_time_us) * 1000 ns`; more than [discontinuityTolerance] apart
///   (or the ESP32 time going backwards) means the timer restarted.
/// - Missing reports are counted from the tick deltas: each delta spans
///   `round(delta / period)` periods, so `that - 1` reports are missing. The
///   period is a low percentile ([periodQuantile], default the lower quartile)
///   of recent deltas, not the median: when a link loses half or more of the
///   reports the median is already a multiple of the true period and would
///   hide the loss. Until [warmup] deltas are known nothing is counted; those
///   deltas are settled once the period is known.
class TickTimer {
  TickTimer({
    this.window = 256,
    this.warmup = 8,
    this.periodQuantile = 0.25,
    this.discontinuityTolerance = const Duration(milliseconds: 100),
  });

  final int window;
  final int warmup;
  final double periodQuantile;
  final Duration discontinuityTolerance;

  int? _prevTicks;
  int? _prevRxUs;
  final List<int> _recent = []; // recent non-zero deltas, in ticks
  final List<int> _pending = []; // deltas not yet counted for missing
  final List<double> _dts = []; // recent dt, seconds
  double _maxDt = 0;
  int _missing = 0;
  int _steps = 0;
  int _discontinuities = 0;
  int _elapsedTicks = 0;
  int _rxElapsedUs = 0;

  /// Reports estimated lost between the controller and the app, from tick
  /// deltas. Includes reports lost before the ESP32 saw them.
  int get missing => _missing;

  /// Steps accepted (excluding baselines and discontinuities).
  int get steps => _steps;
  int get discontinuities => _discontinuities;

  /// Report period in ticks, or null until enough deltas were seen.
  int? get periodTicks {
    if (_recent.length < warmup) return null;
    final sorted = List<int>.of(_recent)..sort();
    final i = (periodQuantile * (sorted.length - 1)).round();
    return sorted[i];
  }

  /// Ratio of controller time (ticks at 100 ns) to ESP32 receive time over
  /// all accepted steps. About 1.0 if the tick unit is right; null before
  /// any step. A diagnostic for the unverified 100 ns unit.
  double? get tickClockRatio => _rxElapsedUs <= 0
      ? null
      : (_elapsedTicks * wmrTickNanoseconds / 1000.0) / _rxElapsedUs;

  DtStats get dtStats {
    if (_dts.isEmpty) return const DtStats();
    final sorted = List<double>.of(_dts)..sort();
    double at(double q) => sorted[(q * (sorted.length - 1)).round()];
    return DtStats(
      count: sorted.length,
      p50: at(0.5),
      p95: at(0.95),
      max: _maxDt,
    );
  }

  /// Forgets the baseline (not the totals). The next [advance] is a baseline.
  void rebaseline() {
    _prevTicks = null;
    _prevRxUs = null;
  }

  TickStep advance(int deviceTicks, int rxTimeUs) {
    final prevTicks = _prevTicks;
    final prevRx = _prevRxUs;
    _prevTicks = deviceTicks;
    _prevRxUs = rxTimeUs;
    if (prevTicks == null || prevRx == null) {
      return const TickStep(TickStepKind.baseline);
    }

    final dtTicks = tickDelta(prevTicks, deviceTicks);
    final tickNs = dtTicks * wmrTickNanoseconds;
    final rxNs = (rxTimeUs - prevRx) * 1000;
    if (rxNs < 0 ||
        (tickNs - rxNs).abs() > discontinuityTolerance.inMicroseconds * 1000) {
      _discontinuities++;
      _recent.clear();
      _pending.clear();
      return const TickStep(TickStepKind.discontinuity);
    }

    final dt = dtTicks * wmrTickSeconds;
    _steps++;
    _elapsedTicks += dtTicks;
    _rxElapsedUs += rxTimeUs - prevRx;
    _dts.add(dt);
    if (_dts.length > window) _dts.removeAt(0);
    if (dt > _maxDt) _maxDt = dt;
    if (dtTicks > 0) _count(dtTicks);
    return TickStep(TickStepKind.step, dtTicks: dtTicks, dtSeconds: dt);
  }

  void _count(int dtTicks) {
    _recent.add(dtTicks);
    if (_recent.length > window) _recent.removeAt(0);
    final period = periodTicks;
    if (period == null) {
      _pending.add(dtTicks);
      return;
    }
    for (final d in _pending) {
      _missing += _lost(d, period);
    }
    _pending.clear();
    _missing += _lost(dtTicks, period);
  }

  static int _lost(int dtTicks, int period) {
    if (period <= 0) return 0;
    final n = (dtTicks / period).round() - 1;
    return n > 0 ? n : 0;
  }
}
