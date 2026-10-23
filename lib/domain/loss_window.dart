/// Received and missing report counters at one instant.
class LossSample {
  const LossSample({
    required this.timeUs,
    required this.records,
    required this.missing,
  });

  /// Phone monotonic clock, same origin as [DecodedHandStats.rateHz].
  final int timeUs;
  final int records;
  final int missing;
}

/// Counters received and missing over a trailing window.
class LossWindowStats {
  const LossWindowStats({
    required this.records,
    required this.missing,
    required this.spanUs,
  });

  /// Reports received inside the window.
  final int records;

  /// Reports estimated missing inside the window (tick deltas).
  final int missing;

  /// Time from the first to the last sample of the window.
  final int spanUs;

  /// Missing reports as a share of expected reports, 0 when nothing was
  /// expected. Uses double arithmetic so counters near the integer limit
  /// cannot overflow when added.
  double get loss {
    final received = records.toDouble();
    final lost = missing.toDouble();
    final expected = received + lost;
    return expected == 0 ? 0 : lost / expected;
  }
}

/// A trailing window of [LossSample]s, one per hand.
///
/// Mirrors the bridge's 5 s statistics interval (WMR_Bridge
/// `WMR_CFG_STATS_INTERVAL_MS`): the loss is the growth of received and
/// missing reports between a sample at least [window] old and the newest
/// sample. Nothing is reported until the window has filled, so the figure is
/// always over a real five seconds rather than a shorter start-up stretch. A
/// gap longer than [window], or counters that go backwards, start the window
/// over.
class LossWindow {
  LossWindow({this.window = const Duration(seconds: 5)});

  final Duration window;

  final List<LossSample> _samples = [];

  int get _windowUs => window.inMicroseconds;

  /// Adds one sample. Samples must arrive in time order; a backwards clock
  /// starts the window over.
  void add(int timeUs, int records, int missing) {
    if (_samples.isNotEmpty) {
      final last = _samples.last;
      if (timeUs < last.timeUs) {
        _samples.clear();
      } else if (timeUs - last.timeUs > _windowUs) {
        // Nothing arrived for longer than the window: the next sample starts
        // a new one instead of spanning the gap.
        _samples.clear();
      }
    }
    _samples.add(
      LossSample(timeUs: timeUs, records: records, missing: missing),
    );

    final cutoff = timeUs - _windowUs;
    var keepFrom = 0;
    for (var i = 0; i < _samples.length; i++) {
      if (_samples[i].timeUs <= cutoff) {
        keepFrom = i;
      } else {
        break;
      }
    }
    if (keepFrom > 0) _samples.removeRange(0, keepFrom);
  }

  /// The trailing window ending at the newest sample, or null before the
  /// window has filled, after [nowUs] is more than [window] past the newest
  /// sample, or when the counters went backwards.
  LossWindowStats? statsAt(int nowUs) {
    if (_samples.isEmpty) return null;
    final end = _samples.last;
    if (nowUs - end.timeUs > _windowUs) return null;

    final cutoff = end.timeUs - _windowUs;
    LossSample? base;
    for (final s in _samples) {
      if (s.timeUs <= cutoff) {
        base = s;
      } else {
        break;
      }
    }
    if (base == null) return null;

    final records = end.records - base.records;
    final missing = end.missing - base.missing;
    if (records < 0 || missing < 0) return null;
    return LossWindowStats(
      records: records,
      missing: missing,
      spanUs: end.timeUs - base.timeUs,
    );
  }

  /// Forgets every sample: the next [statsAt] returns null until the window
  /// fills again.
  void reset() => _samples.clear();
}
