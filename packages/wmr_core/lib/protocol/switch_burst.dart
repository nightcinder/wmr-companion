/// Timing for the three IMU samples in one Nintendo Switch `0x30` report.
///
/// A Switch `0x30` (0x31/0x32/0x33) report repeats its 6-axis sample three
/// times in one Bluetooth packet. On a Joy-Con pushed every 15 ms the spacing
/// is 5 ms; on a Pro Controller that pushes faster the spacing is the report
/// period divided by three (Linux `hid-nintendo.c` measures 8-11 ms pushes).
/// The bridge sends one FF12/FF14 record per sample, and all three carry the
/// same per-hand `sequence`: that number identifies the raw frame, not one
/// sample. The report itself has no per-sample timestamp, so a bridge may
/// stamp all three with the packet's receive time.
///
/// [SwitchBurstTimestamps] turns that into the sample clock the pipeline
/// needs: the first record of a burst keeps its device ticks, the second and
/// third get `anchor + interval` and `anchor + 2 * interval`. The interval is
/// the previous burst's anchor-to-anchor period divided by three, clamped to
/// 1-5 ms; the first burst of a stream uses the nominal 5 ms. A new sequence
/// (or a hand change) starts a new burst. If the bridge already spaced the
/// samples, the supplied offset wins and the result is the same values, so
/// applying this twice is harmless.
///
/// Callers must only use it for hands whose FF17 model is Switch; repeated
/// sequences are a timing error on every other model.
library;

import '../protocol/decoded_record.dart';

/// Nominal device ticks between two Switch samples: 5 ms at 100 ns per tick.
/// Also the upper clamp for a measured interval.
const int switchSampleIntervalTicks = 5000 * 10;

/// Lower clamp for a measured sample interval: 1 ms.
const int switchMinSampleIntervalTicks = 1000 * 10;

/// Samples in one Switch `0x30` report.
const int switchSamplesPerBurst = 3;

class SwitchBurstTimestamps {
  int _hand = -1;
  int _sequence = -1;
  int _index = 0;
  int _anchorTicks = 0;
  int _intervalTicks = switchSampleIntervalTicks;

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
    _intervalTicks = switchSampleIntervalTicks;
  }

  /// The sample interval implied by a new anchor [current] after [previous].
  /// The first burst of a stream, a duplicate anchor and a hand change keep
  /// the nominal 5 ms.
  int _measureInterval(int previous, int current) {
    final period = (current - previous) & 0xffffffff;
    if (period == 0) return switchSampleIntervalTicks;
    return (period ~/ switchSamplesPerBurst).clamp(
      switchMinSampleIntervalTicks,
      switchSampleIntervalTicks,
    );
  }

  /// Returns [r] with the device ticks of its place in the burst. The
  /// receive time is left as the bridge sent it: it is the packet's arrival
  /// time and is not a sensor clock.
  DecodedRecord apply(DecodedRecord r) {
    final sameBurst =
        r.hand == _hand &&
        r.sequence == _sequence &&
        _index + 1 < switchSamplesPerBurst;
    if (sameBurst) {
      _index++;
      // A bridge that already spaced the three samples supplies the offset.
      final supplied = (r.deviceTicks - _anchorTicks) & 0xffffffff;
      if (supplied > 0) {
        _intervalTicks = (supplied ~/ _index).clamp(
          switchMinSampleIntervalTicks,
          switchSampleIntervalTicks,
        );
      }
    } else {
      final hadBurst = _hand != -1;
      if (hadBurst && r.hand == _hand) {
        _intervalTicks = _measureInterval(_anchorTicks, r.deviceTicks);
      } else {
        _intervalTicks = switchSampleIntervalTicks;
      }
      _hand = r.hand;
      _sequence = r.sequence;
      _index = 0;
      _anchorTicks = r.deviceTicks;
    }
    if (_index == 0) return r;
    return r.copyWith(
      deviceTicks: (_anchorTicks + _index * _intervalTicks) & 0xffffffff,
    );
  }
}
