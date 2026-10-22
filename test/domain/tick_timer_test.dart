import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/tick_timer.dart';
import 'package:wmr_companion/protocol/decoded_record.dart';

import 'sim.dart';

const p = nominalPeriodTicks;

/// Feeds [ticks] with rx times that follow them.
List<TickStep> feed(
  TickTimer t,
  Iterable<int> ticks, {
  int rxOrigin = 1000000,
}) {
  return [for (final k in ticks) t.advance(k & 0xffffffff, rxOrigin + k ~/ 10)];
}

void main() {
  test('the first sample is a baseline', () {
    final t = TickTimer();
    expect(t.advance(5000, 0).kind, TickStepKind.baseline);
  });

  test('dt is the tick delta at 100 ns', () {
    final t = TickTimer();
    final steps = feed(t, [0, p, 2 * p]);
    expect(steps[1].kind, TickStepKind.step);
    expect(steps[1].dtTicks, p);
    expect(steps[1].dtSeconds, closeTo(p * 1e-7, 1e-12));
    expect(steps[1].dtSeconds, closeTo(0.00588, 1e-6));
  });

  test('wraparound at 2^32 does not produce a negative or huge dt', () {
    final t = TickTimer();
    const start = 0xffffffff - 2 * p;
    final steps = feed(t, [for (var i = 0; i < 6; i++) start + i * p]);
    for (final s in steps.skip(1)) {
      expect(s.kind, TickStepKind.step);
      expect(s.dtTicks, p);
    }
    expect(t.discontinuities, 0);
  });

  test('a lost report makes the next dt larger, not a discontinuity', () {
    final t = TickTimer();
    final steps = feed(t, [0, p, 2 * p, 4 * p]); // one missing
    expect(steps.last.kind, TickStepKind.step);
    expect(steps.last.dtTicks, 2 * p);
    expect(steps.last.dtSeconds, closeTo(2 * p * 1e-7, 1e-12));
  });

  test(
    'ticks and receive time disagreeing by over 100 ms is a discontinuity',
    () {
      final t = TickTimer();
      t.advance(0, 1000000);
      t.advance(p, 1000000 + p ~/ 10);
      // Controller timer restarted: ticks jump back while rx time moves on.
      final s = t.advance(10, 1000000 + 2 * p ~/ 10);
      expect(s.kind, TickStepKind.discontinuity);
      expect(t.discontinuities, 1);
      // The sample is the new baseline.
      expect(t.advance(10 + p, 1000000 + 3 * p ~/ 10).kind, TickStepKind.step);
    },
  );

  test('the ESP32 clock going backwards is a discontinuity', () {
    final t = TickTimer();
    t.advance(0, 5000000);
    expect(t.advance(p, 100).kind, TickStepKind.discontinuity);
  });

  test('a small disagreement within the tolerance is fine', () {
    final t = TickTimer();
    t.advance(0, 1000000);
    // 30 ms of receive-time jitter on a 5.88 ms step.
    expect(t.advance(p, 1000000 + p ~/ 10 + 30000).kind, TickStepKind.step);
  });

  test('rebaseline makes the next sample a baseline without dt', () {
    final t = TickTimer();
    feed(t, [0, p]);
    t.rebaseline();
    expect(
      t.advance(50 * p, 1000000 + 50 * p ~/ 10).kind,
      TickStepKind.baseline,
    );
  });

  group('missing reports from tick deltas', () {
    test('none lost, none counted', () {
      final t = TickTimer();
      feed(t, [for (var i = 0; i < 100; i++) i * p]);
      expect(t.missing, 0);
      expect(t.periodTicks, p);
    });

    test('a single drop is counted once', () {
      final t = TickTimer();
      final ticks = [
        for (var i = 0; i < 100; i++)
          if (i != 50) i * p,
      ];
      feed(t, ticks);
      expect(t.missing, 1);
    });

    test('a long outage counts every missing report', () {
      final t = TickTimer();
      feed(t, [
        for (var i = 0; i < 30; i++) i * p,
        for (var i = 40; i < 60; i++) i * p, // 10 missing
      ]);
      expect(t.missing, 10);
    });

    test('losses before the period is known are settled afterwards', () {
      final t = TickTimer();
      // Drop at index 2 and 4, while still in warm-up.
      final ticks = [
        for (var i = 0; i < 60; i++)
          if (i != 2 && i != 4) i * p,
      ];
      feed(t, ticks);
      expect(t.missing, 2);
    });

    test(
      'half the reports lost: the median would hide it, the quartile does not',
      () {
        final t = TickTimer();
        // Deterministic pattern: deltas of 1, 2, 1, 2, ... periods (LEFT lost
        // about half in one capture). Median delta is 1.5 periods.
        var k = 0;
        final ticks = <int>[0];
        for (var i = 0; i < 200; i++) {
          k += i.isEven ? 1 : 2;
          ticks.add(k * p);
        }
        feed(t, ticks);
        expect(t.periodTicks, p);
        // 100 deltas of 2 periods, one lost each.
        expect(t.missing, 100);
      },
    );

    test('period is the median of deltas up to 1.5x the 10th percentile', () {
      final t = TickTimer();
      var k = 0;
      final ticks = <int>[0];
      // Jittered deltas: 20 of 49000 and 20 of 50000 ticks, interleaved.
      for (var i = 0; i < 40; i++) {
        k += i.isEven ? 49000 : 50000;
        ticks.add(k);
      }
      feed(t, ticks);
      // The 10th percentile alone would give 49000; the firmware definition
      // is the median of the deltas within 1.5x of it.
      expect(t.periodTicks, 49500);
      expect(t.periodMs, closeTo(4.95, 1e-9));
      expect(t.missing, 0);
    });

    test('long deltas do not pull the period up (firmware 1.5x rule)', () {
      final t = TickTimer();
      var k = 0;
      final ticks = <int>[0];
      // Two thirds of the deltas are two periods long.
      for (var i = 0; i < 60; i++) {
        k += i % 3 == 0 ? 49800 : 99600;
        ticks.add(k);
      }
      feed(t, ticks);
      expect(t.periodTicks, 49800);
      expect(t.missing, 40);
    });

    test('nothing is counted before 16 deltas, then they are settled', () {
      final t = TickTimer();
      // 15 deltas: a drop at 5 (one 2-period delta), period unknown.
      final ticks = [
        for (var i = 0; i <= 17; i++)
          if (i != 5) i * p,
      ];
      feed(t, ticks.take(16)); // 15 deltas
      expect(t.periodTicks, isNull);
      expect(t.missing, 0);
      feed(t, ticks.skip(16));
      expect(t.periodTicks, p);
      expect(t.missing, 1);
    });

    test('a repeated tick value is ignored', () {
      final t = TickTimer();
      feed(t, [
        for (var i = 0; i < 40; i++) ...[i * p, i * p],
      ]);
      expect(t.missing, 0);
      expect(t.periodTicks, p);
    });

    test('a delta over 5 s is not counted as missing', () {
      final t = TickTimer();
      final ticks = [
        for (var i = 0; i < 30; i++) i * p,
        29 * p + 60000000, // 6 s later
        29 * p + 60000000 + p,
      ];
      feed(t, ticks);
      expect(t.missing, 0);
      expect(t.longGaps, 1);
    });

    test('counting survives the 32-bit wrap', () {
      final t = TickTimer();
      const start = 0xffffffff - 20 * p;
      feed(t, [
        for (var i = 0; i < 60; i++)
          if (i != 30) start + i * p,
      ]);
      expect(t.missing, 1);
      expect(t.discontinuities, 0);
    });

    test('a discontinuity is not counted as loss', () {
      final t = TickTimer();
      feed(t, [for (var i = 0; i < 30; i++) i * p]);
      t.advance(7, 1000000 + 31 * p ~/ 10); // timer restart
      expect(t.missing, 0);
    });
  });

  group('dt statistics', () {
    test('p50 and max', () {
      final t = TickTimer();
      // 9 steps of one period, one of five.
      feed(t, [for (var i = 0; i < 10; i++) i * p, 14 * p]);
      final s = t.dtStats;
      expect(s.count, 10);
      expect(s.p50, closeTo(p * 1e-7, 1e-12));
      expect(s.max, closeTo(5 * p * 1e-7, 1e-12));
    });

    test('empty before any step', () {
      expect(TickTimer().dtStats.count, 0);
    });
  });

  test('tick/clock ratio is 1.0 when the unit is right', () {
    final t = TickTimer();
    feed(t, [for (var i = 0; i < 50; i++) i * p]);
    expect(t.tickClockRatio, closeTo(1.0, 0.001));
  });

  test('tick/clock ratio exposes a wrong unit', () {
    final t = TickTimer(discontinuityTolerance: const Duration(seconds: 100));
    // Controller really ticks at 1 us: rx time advances 10x faster.
    for (var i = 0; i < 50; i++) {
      t.advance(i * p, 1000000 + i * p);
    }
    expect(t.tickClockRatio, closeTo(0.1, 0.001));
    expect(wmrTickNanoseconds, 100);
  });
}
