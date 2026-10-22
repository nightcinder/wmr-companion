import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/gyro_bias.dart';

const dt = 0.00588;

/// Deterministic noise in [-amp, amp].
double noise(int i, double amp) =>
    amp * math.sin(i * 12.9898) * math.cos(i * 4.1414);

void main() {
  test('estimates the bias from the first stationary second', () {
    final e = GyroBiasEstimator();
    var done = false;
    for (var i = 0; i < 400 && !done; i++) {
      done = e.add(
        [
          0.03 + noise(i, 0.01),
          -0.02 + noise(i + 1, 0.01),
          0.05 + noise(i + 2, 0.01),
        ],
        [10 + noise(i + 3, 0.05), noise(i + 4, 0.05), noise(i + 5, 0.05)],
        dt,
      );
    }
    expect(done, isTrue);
    expect(e.calibrated, isTrue);
    expect(e.bias[0], closeTo(0.03, 0.005));
    expect(e.bias[1], closeTo(-0.02, 0.005));
    expect(e.bias[2], closeTo(0.05, 0.005));
    expect(e.rejectedWindows, 0);
  });

  test('completes after about one second of dt, not before', () {
    final e = GyroBiasEstimator();
    var samples = 0;
    while (!e.calibrated) {
      e.add([0, 0, 0], [10, 0, 0], dt);
      samples++;
    }
    expect(samples * dt, closeTo(1.0, 0.01));
  });

  test('reports progress', () {
    final e = GyroBiasEstimator();
    for (var i = 0; i < 85; i++) {
      e.add([0, 0, 0], [10, 0, 0], dt);
    }
    expect(e.progress, closeTo(0.5, 0.05));
  });

  test('motion rejects the window and a later still second succeeds', () {
    final e = GyroBiasEstimator();
    // One second of waving.
    for (var i = 0; i < 175; i++) {
      e.add([math.sin(i * 0.2), 0, 0], [10 + math.cos(i * 0.2), 0, 0], dt);
    }
    expect(e.calibrated, isFalse);
    expect(e.rejectedWindows, greaterThan(0));
    for (var i = 0; i < 175; i++) {
      e.add([0.01, 0, 0], [10, 0, 0], dt);
    }
    expect(e.calibrated, isTrue);
    // The window may still hold a sample or two of the motion.
    expect(e.bias[0], closeTo(0.01, 0.003));
  });

  test('a steady rotation is not mistaken for bias', () {
    final e = GyroBiasEstimator();
    for (var i = 0; i < 400; i++) {
      e.add([1.0, 0, 0], [10, 0, 0], dt);
    }
    expect(e.calibrated, isFalse);
  });

  test('changing accel magnitude (shaking) rejects the window', () {
    final e = GyroBiasEstimator();
    for (var i = 0; i < 400; i++) {
      e.add([0, 0, 0], [10 + 3 * math.sin(i * 0.3), 0, 0], dt);
    }
    expect(e.calibrated, isFalse);
  });

  test('a gap restarts the window', () {
    final e = GyroBiasEstimator();
    for (var i = 0; i < 100; i++) {
      e.add([0, 0, 0], [10, 0, 0], dt);
    }
    e.add([0, 0, 0], [10, 0, 0], 0.5); // longer than maxStep
    expect(e.progress, 0);
    for (var i = 0; i < 100; i++) {
      e.add([0, 0, 0], [10, 0, 0], dt);
    }
    expect(e.calibrated, isFalse);
  });

  test('restart forgets the bias and looks again', () {
    final e = GyroBiasEstimator();
    for (var i = 0; i < 400; i++) {
      e.add([0.02, 0, 0], [10, 0, 0], dt);
    }
    expect(e.calibrated, isTrue);
    e.restart();
    expect(e.calibrated, isFalse);
    expect(e.bias, [0, 0, 0]);
    for (var i = 0; i < 400; i++) {
      e.add([-0.04, 0, 0], [10, 0, 0], dt);
    }
    expect(e.bias[0], closeTo(-0.04, 1e-9));
  });

  test('ignores non-finite input', () {
    final e = GyroBiasEstimator();
    for (var i = 0; i < 100; i++) {
      e.add([0, 0, 0], [10, 0, 0], dt);
    }
    e.add([double.nan, 0, 0], [10, 0, 0], dt);
    expect(e.progress, 0);
  });
}
