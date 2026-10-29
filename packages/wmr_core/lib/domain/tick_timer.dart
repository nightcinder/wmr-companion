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
/// - Missing reports use the firmware's definition (WMR_Bridge
///   `src/wmr_devloss.c`, `docs/COUNTERS.md`, `tools/analyze_capture.py`
///   `device_loss`): each delta spans `round(delta / period)` periods, so
///   `that - 1` reports are missing. The period is the median of the deltas
///   not longer than 1.5x the 10th-percentile delta (`sorted[n ~/ 10]`) of a
///   sliding window of the last [window] deltas, refreshed every [refresh]
///   deltas. Nothing is counted until [warmup] deltas exist; those are then
///   counted retroactively. A zero delta is ignored; a delta over
///   [maxDeltaTicks] (5 s) is not counted as missing and not used for the
///   period. Like the firmware it cannot see perfectly uniform loss.
class TickTimer {
  TickTimer({
    this.window = 256,
    this.warmup = 16,
    this.refresh = 32,
    this.maxDeltaTicks = 50000000,
    this.discontinuityTolerance = const Duration(milliseconds: 100),
  });

  final int window;
  final int warmup;
  final int refresh;
  final int maxDeltaTicks;
  final Duration discontinuityTolerance;

  int? _prevTicks;
  int? _prevRxUs;
  final List<int> _recent = []; // last deltas in arrival order, in ticks
  int _sinceRefresh = 0;
  int? _period;
  final List<double> _dts = []; // recent dt, seconds
  double _maxDt = 0;
  int _missing = 0;
  int _steps = 0;
  int _discontinuities = 0;
  int _longGaps = 0;
  int _elapsedTicks = 0;
  int _rxElapsedUs = 0;

  /// Reports estimated lost between the controller and the app, from tick
  /// deltas. Includes reports lost before the ESP32 saw them.
  int get missing => _missing;

  /// Steps accepted (excluding baselines and discontinuities).
  int get steps => _steps;
  int get discontinuities => _discontinuities;

  /// Deltas over [maxDeltaTicks] that were left out of the missing count.
  int get longGaps => _longGaps;

  /// Nominal report period in ticks (firmware definition, see above), or
  /// null until [warmup] deltas were seen.
  int? get periodTicks => _period;

  /// [periodTicks] in milliseconds, or null.
  double? get periodMs {
    final p = _period;
    return p == null ? null : p * wmrTickSeconds * 1000;
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
      _sinceRefresh = 0;
      _period = null;
      return const TickStep(TickStepKind.discontinuity);
    }

    final dt = dtTicks * wmrTickSeconds;
    _steps++;
    _elapsedTicks += dtTicks;
    _rxElapsedUs += rxTimeUs - prevRx;
    _dts.add(dt);
    if (_dts.length > window) _dts.removeAt(0);
    if (dt > _maxDt) _maxDt = dt;
    if (dtTicks > maxDeltaTicks) {
      _longGaps++;
    } else if (dtTicks > 0) {
      _count(dtTicks);
    }
    return TickStep(TickStepKind.step, dtTicks: dtTicks, dtSeconds: dt);
  }

  /// Mirrors `wmr_devloss_add` after its discontinuity and zero-delta checks.
  void _count(int dtTicks) {
    _recent.add(dtTicks);
    if (_recent.length > window) _recent.removeAt(0);
    _sinceRefresh++;

    if (_period == null) {
      if (_recent.length >= warmup) {
        final p = _estimatePeriod();
        _sinceRefresh = 0;
        if (p > 0) {
          _period = p;
          // Deltas collected during warm-up are counted retroactively.
          for (final d in _recent) {
            _missing += _lost(d, p);
          }
        }
      }
      return;
    }
    _missing += _lost(dtTicks, _period!);
    if (_sinceRefresh >= refresh) {
      final p = _estimatePeriod();
      if (p > 0) _period = p;
      _sinceRefresh = 0;
    }
  }

  /// Median of the window deltas that are at most 1.5x the 10th percentile
  /// (`sorted[n ~/ 10]`); 0 if that reference is 0. Integer arithmetic as in
  /// the firmware.
  int _estimatePeriod() {
    final sorted = List<int>.of(_recent)..sort();
    final ref = sorted[sorted.length ~/ 10];
    if (ref == 0) return 0;
    final limit = ref + ref ~/ 2;
    var m = 0;
    while (m < sorted.length && sorted[m] <= limit) {
      m++;
    }
    if (m == 0) return 0;
    if (m.isOdd) return sorted[m ~/ 2];
    return (sorted[m ~/ 2 - 1] + sorted[m ~/ 2]) ~/ 2;
  }

  /// `round(delta / period) - 1`, at least 0, rounding half up as the
  /// firmware's `(delta + period / 2) / period`.
  static int _lost(int dtTicks, int period) {
    final k = (dtTicks + period ~/ 2) ~/ period;
    return k > 1 ? k - 1 : 0;
  }
}

// ONY-513 CI probe: Dart-only change, no Android source touched.
