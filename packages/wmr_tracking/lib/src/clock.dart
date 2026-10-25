/// A monotonic host clock in nanoseconds.
typedef HostClock = int Function();

/// Aligns a source's monotonic timestamps to the host monotonic clock.
///
/// Vendor timestamps are in their own epoch: Viture's Carina pose is
/// "monotonic seconds", XREAL runs inside Unity, Android XR uses the ARCore
/// clock, and the BLE transport's `Stopwatch` has yet another origin. Fusion
/// compares controller samples with tracking frames, so both must be on one
/// clock.
///
/// The first sample defines the offset. Later samples are low-pass filtered to
/// absorb transport jitter, and offsets that jump by more than
/// [maxCorrection] are rejected unless the source clock itself went
/// backwards (a device or session restart), in which case the aligner rebases.
class SourceClockAligner {
  SourceClockAligner({
    this.maxCorrection = const Duration(milliseconds: 50),
    this.smoothing = 0.125,
  }) : assert(smoothing > 0 && smoothing <= 1);

  /// Largest arrival-time error treated as jitter rather than a clock reset.
  final Duration maxCorrection;

  /// Low-pass weight for a new offset; 1 trusts every sample.
  final double smoothing;

  int? _offsetNs;
  int? _lastSourceNs;

  /// The current host-minus-source offset, or null before the first sample.
  int? get offsetNs => _offsetNs;

  /// Maps [sourceTimeNs] to the host clock, using [hostTimeNs] as the arrival
  /// estimate. A rejected outlier is still mapped with the previous offset;
  /// it is never dropped or allowed to move time backwards.
  int align({required int sourceTimeNs, required int hostTimeNs}) {
    final previousSource = _lastSourceNs;
    _lastSourceNs = sourceTimeNs;

    final offset = _offsetNs;
    if (offset == null ||
        (previousSource != null && sourceTimeNs < previousSource)) {
      final rebased = hostTimeNs - sourceTimeNs;
      _offsetNs = rebased;
      return hostTimeNs;
    }

    final rawOffset = hostTimeNs - sourceTimeNs;
    final delta = rawOffset - offset;
    if (delta.abs() > maxCorrection.inMicroseconds * 1000) {
      return sourceTimeNs + offset;
    }

    final next = offset + (delta * smoothing).round();
    _offsetNs = next;
    return sourceTimeNs + next;
  }

  /// Forgets the estimate; the next [align] call rebases.
  void reset() {
    _offsetNs = null;
    _lastSourceNs = null;
  }
}

/// Stamps arrival times on the host monotonic clock.
class TrackingClock {
  TrackingClock({required this.hostClock, SourceClockAligner? aligner})
    : aligner = aligner ?? SourceClockAligner();

  final HostClock hostClock;
  final SourceClockAligner aligner;

  /// Nanoseconds on the host clock right now.
  int nowNs() => hostClock();
}
