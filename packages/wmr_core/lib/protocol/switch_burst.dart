/// Timing for the three IMU samples in one Nintendo Switch `0x30` report.
///
/// A Switch `0x30` (0x31/0x32/0x33) report repeats its 6-axis sample three
/// times, 5 ms apart, in one Bluetooth packet. The bridge sends one FF12/FF14
/// record per sample, and all three carry the same per-hand `sequence`: that
/// number identifies the raw frame, not one sample. The report itself has no
/// per-sample timestamp, so a bridge may stamp all three with the packet's
/// receive time.
///
/// [SwitchBurstTimestamps] turns that into the 5 ms sample clock the pipeline
/// needs: the first record of a burst keeps its device ticks, the second and
/// third get `anchor + 5 ms` and `anchor + 10 ms`. A new sequence (or a hand
/// change) starts a new burst. If the bridge already spaced the samples, the
/// result is the same values, so applying this twice is harmless.
///
/// Callers must only use it for hands whose FF17 model is Switch; repeated
/// sequences are a timing error on every other model.
library;

import '../protocol/decoded_record.dart';

/// Device ticks in one 5 ms Switch sample interval (100 ns per tick).
const int switchSampleIntervalTicks = 5000 * 10;

/// Samples in one Switch `0x30` report.
const int switchSamplesPerBurst = 3;

class SwitchBurstTimestamps {
  int _hand = -1;
  int _sequence = -1;
  int _index = 0;
  int _anchorTicks = 0;

  /// Index of the last sample in its burst: 0 for the first, 1 and 2 for the
  /// following two. Used by the service to skip sequence accounting for the
  /// repeated records.
  int get sampleIndex => _index;

  /// Whether the last [apply] returned a repeated record of a burst.
  bool get isBurstRepeat => _index > 0;

  /// Forgets the current burst. The next [apply] starts a new one.
  void reset() {
    _hand = -1;
    _sequence = -1;
    _index = 0;
    _anchorTicks = 0;
  }

  /// Returns [r] with the device ticks of its place in the burst. The
  /// receive time is left as the bridge sent it: it is the packet's arrival
  /// time and is not a sensor clock.
  DecodedRecord apply(DecodedRecord r) {
    if (r.hand == _hand &&
        r.sequence == _sequence &&
        _index + 1 < switchSamplesPerBurst) {
      _index++;
    } else {
      _hand = r.hand;
      _sequence = r.sequence;
      _index = 0;
      _anchorTicks = r.deviceTicks;
    }
    if (_index == 0) return r;
    return r.copyWith(
      deviceTicks:
          (_anchorTicks + _index * switchSampleIntervalTicks) & 0xffffffff,
    );
  }
}
