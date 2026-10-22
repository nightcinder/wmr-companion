import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/hand_pipeline.dart';
import 'package:wmr_companion/domain/stick_centre.dart';

import 'sim.dart';

const full = 32767;
const dt = 0.005;

/// Feeds [seconds] of the same raw reading, returns the last output.
List<double> hold(
  StickNormalizer n,
  int x,
  int y,
  double seconds, {
  StickConfig config = const StickConfig(),
  bool busy = false,
}) {
  var out = const <double>[0, 0];
  for (var t = 0.0; t < seconds; t += dt) {
    out = n.process(x, y, dt: dt, busy: busy, config: config);
  }
  return out;
}

int raw(double v) => (v * full).round();

void main() {
  test('rest offset is learned after about a second and removed', () {
    final n = StickNormalizer();
    // A y offset of 0.148 of full scale (one user-reported figure).
    hold(n, 0, raw(0.148), 0.5);
    expect(n.hasCentre, isFalse);
    final out = hold(n, 0, raw(0.148), 1.0);
    expect(n.hasCentre, isTrue);
    expect(n.centre[1], closeTo(0.148, 1e-3));
    expect(out, [0, 0]);
  });

  test('full deflection still reaches 1.0 after the centre is removed', () {
    final n = StickNormalizer();
    hold(n, 0, raw(0.148), 1.5);
    const cfg = StickConfig(learn: false);
    expect(hold(n, 0, full, 0.01, config: cfg)[1], closeTo(1, 1e-6));
    expect(hold(n, 0, -full, 0.01, config: cfg)[1], closeTo(-1, 1e-6));
    // Halfway up the positive side maps to about half after rescaling,
    // before the dead zone: (0.574 - 0.148) / (1 - 0.148) = 0.5.
    final mid = hold(
      n,
      0,
      raw((1 + 0.148) / 2),
      0.01,
      config: const StickConfig(deadZone: 0, learn: false),
    );
    expect(mid[1], closeTo(0.5, 1e-3));
  });

  test('radial dead zone zeroes small values and keeps the extremes', () {
    final n = StickNormalizer();
    const cfg = StickConfig(deadZone: 0.1, learn: false);
    expect(hold(n, raw(0.05), raw(0.05), 0.01, config: cfg), [0, 0]);
    expect(hold(n, full, 0, 0.01, config: cfg)[0], closeTo(1, 1e-6));
    // Just outside the zone starts near zero, not at the zone's edge value.
    final out = hold(n, raw(0.2), 0, 0.01, config: cfg);
    expect(out[0], closeTo((0.2 - 0.1) / 0.9, 1e-3));
    // Diagonal corner is clamped to unit length.
    final corner = hold(n, full, full, 0.01, config: cfg);
    expect(corner[0] * corner[0] + corner[1] * corner[1], closeTo(1, 1e-6));
  });

  test('default dead zone is 0.05', () {
    expect(const StickConfig().deadZone, 0.05);
    expect(const StickConfig().learn, isTrue);
  });

  test('no learning while deflected beyond the window', () {
    final n = StickNormalizer();
    hold(n, 0, raw(0.6), 3);
    expect(n.hasCentre, isFalse);
    expect(n.centre, [0, 0]);
  });

  test('no learning while moving, busy, or with learning off', () {
    final n = StickNormalizer();
    // Wandering inside the window never sits still for a second.
    for (var i = 0; i < 600; i++) {
      n.process(
        raw(i.isEven ? 0.0 : 0.1),
        0,
        dt: dt,
        busy: false,
        config: const StickConfig(),
      );
    }
    expect(n.hasCentre, isFalse);
    hold(n, 0, raw(0.1), 3, busy: true);
    expect(n.hasCentre, isFalse);
    hold(n, 0, raw(0.1), 3, config: const StickConfig(learn: false));
    expect(n.hasCentre, isFalse);
    hold(n, 0, raw(0.1), 1.2);
    expect(n.hasCentre, isTrue);
  });

  test('a gap restarts the candidate', () {
    final n = StickNormalizer();
    hold(n, 0, raw(0.1), 0.8);
    n.process(0, raw(0.1), dt: 0.5, busy: false, config: const StickConfig());
    hold(n, 0, raw(0.1), 0.5);
    expect(n.hasCentre, isFalse);
  });

  test('manual re-centre takes the latest reading, even with learning off', () {
    final n = StickNormalizer();
    n.recentre(); // before any sample: no-op
    expect(n.hasCentre, isFalse);
    const cfg = StickConfig(learn: false);
    hold(n, raw(-0.3), raw(0.4), 0.05, config: cfg);
    n.recentre();
    expect(n.centre[0], closeTo(-0.3, 1e-3));
    expect(n.centre[1], closeTo(0.4, 1e-3));
    expect(hold(n, raw(-0.3), raw(0.4), 0.01, config: cfg), [0, 0]);
  });

  test('reset forgets the centre', () {
    final n = StickNormalizer();
    hold(n, 0, raw(0.1), 1.5);
    expect(n.hasCentre, isTrue);
    n.reset();
    expect(n.hasCentre, isFalse);
    expect(n.centre, [0, 0]);
    expect(n.centreUpdates, 0);
  });

  test('state is per hand in the pipeline', () {
    final left = HandPipeline();
    final right = HandPipeline();
    for (var i = 0; i < 400; i++) {
      final ticks = i * nominalPeriodTicks;
      left.add(record(ticks: ticks, stick: [0, raw(0.148)]), 0);
      right.add(record(ticks: ticks, hand: 1), 0);
    }
    expect(left.stickNormalizer.centre[1], closeTo(0.148, 1e-3));
    expect(right.stickNormalizer.hasCentre, isTrue);
    expect(right.stickNormalizer.centre[1], closeTo(0, 1e-6));
    expect(
      left.stickNormalizer.centre[1],
      isNot(right.stickNormalizer.centre[1]),
    );
  });

  test('pipeline does not learn while a button is held or the gyro moves', () {
    final p = HandPipeline();
    for (var i = 0; i < 400; i++) {
      p.add(
        record(ticks: i * nominalPeriodTicks, stick: [0, raw(0.1)], buttons: 2),
        0,
      );
    }
    expect(p.stickNormalizer.hasCentre, isFalse);
    final q = HandPipeline();
    for (var i = 0; i < 400; i++) {
      q.add(
        record(
          ticks: i * nominalPeriodTicks,
          stick: [0, raw(0.1)],
          gyro: const [1.0, 0, 0],
        ),
        0,
      );
    }
    expect(q.stickNormalizer.hasCentre, isFalse);
  });
}
