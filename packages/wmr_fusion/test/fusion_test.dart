import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:wmr_fusion/wmr_fusion.dart';

const g = 10.0;
const up = Vector3(0, 0, 1);

/// Angle (rad) between the world-frame gravity direction implied by [q] and
/// the measured [accel]; 0 means tilt is exactly right.
double tiltError(Quaternion q, Vector3 accel) => q.rotate(accel).angleTo(up);

/// Simulates a perfect IMU rotating at constant body rate [rate] for
/// [seconds] starting from [start], feeding [f] at [hz]. Returns the truth.
Quaternion simulate(
  OrientationFilter f,
  Vector3 rate,
  double seconds, {
  Quaternion start = Quaternion.identity,
  double hz = 200,
}) {
  final dt = 1 / hz;
  var truth = start;
  final n = (seconds * hz).round();
  f.update(
    gyro: Vector3.zero,
    accel: truth.conjugate().rotate(const Vector3(0, 0, g)),
    dt: dt,
  );
  for (var i = 0; i < n; i++) {
    truth = (truth * Quaternion.fromAxisAngle(rate, rate.length * dt))
        .normalized();
    f.update(
      gyro: rate,
      accel: truth.conjugate().rotate(const Vector3(0, 0, g)),
      dt: dt,
    );
  }
  return truth;
}

void main() {
  group('Quaternion / Vector3', () {
    test('rotate matches axis-angle', () {
      final q = Quaternion.fromAxisAngle(const Vector3(0, 0, 1), math.pi / 2);
      final v = q.rotate(const Vector3(1, 0, 0));
      expect(v.x, closeTo(0, 1e-12));
      expect(v.y, closeTo(1, 1e-12));
    });

    test('euler round trip and conjugate', () {
      final q = Quaternion.fromEuler(yaw: 0.7, pitch: -0.4, roll: 1.1);
      final e = q.toEuler();
      expect(e.yaw, closeTo(0.7, 1e-12));
      expect(e.pitch, closeTo(-0.4, 1e-12));
      expect(e.roll, closeTo(1.1, 1e-12));
      final id = q * q.conjugate();
      expect(id.w, closeTo(1, 1e-12));
      expect(id.x.abs() + id.y.abs() + id.z.abs(), closeTo(0, 1e-12));
    });
  });

  final factories = <String, OrientationFilterBase Function()>{
    'Madgwick': () => MadgwickFilter(beta: 0.05),
    'Mahony': () => MahonyFilter(kp: 1, ki: 0.0),
  };

  for (final entry in factories.entries) {
    group(entry.key, () {
      late OrientationFilterBase f;
      setUp(() => f = entry.value());

      test('static gravity gives correct tilt from first sample', () {
        // Tilted: 30 deg roll and 20 deg pitch, derived from a known pose.
        final pose = Quaternion.fromEuler(yaw: 0, pitch: 0.35, roll: 0.52);
        final accel = pose.conjugate().rotate(const Vector3(0, 0, g));
        f.update(gyro: Vector3.zero, accel: accel, dt: 0.005);
        expect(tiltError(f.orientation, accel), lessThan(1e-6));
        final e = f.orientation.toEuler();
        expect(e.roll, closeTo(0.52, 1e-3));
        expect(e.pitch, closeTo(0.35, 1e-3));
        // Stays put under continued static samples.
        for (var i = 0; i < 400; i++) {
          f.update(gyro: Vector3.zero, accel: accel, dt: 0.005);
        }
        expect(tiltError(f.orientation, accel), lessThan(1e-3));
      });

      test('level and upside-down start', () {
        f.update(gyro: Vector3.zero, accel: const Vector3(0, 0, g), dt: 0.01);
        expect(f.orientation.angleTo(Quaternion.identity), lessThan(1e-9));
        f.reset();
        const flipped = Vector3(0, 0, -g);
        f.update(gyro: Vector3.zero, accel: flipped, dt: 0.01);
        expect(tiltError(f.orientation, flipped), lessThan(1e-9));
      });

      for (final axis in {
        'x': const Vector3(1, 0, 0),
        'y': const Vector3(0, 1, 0),
        'z': const Vector3(0, 0, 1),
      }.entries) {
        test('1 rad/s about ${axis.key} for 1 s integrates to 1 rad', () {
          // Tolerance: 0.02 rad (about 1.1 deg) between estimate and truth.
          final truth = simulate(f, axis.value, 1.0);
          expect(f.orientation.angleTo(truth), lessThan(0.02));
          final e = f.orientation.toEuler();
          final angle = {'x': e.roll, 'y': e.pitch, 'z': e.yaw}[axis.key]!;
          expect(angle, closeTo(1.0, 0.02));
        });
      }

      test('recovers from a wrong initial orientation', () {
        final wrong = Quaternion.fromEuler(yaw: 0, pitch: 0.8, roll: -1.0);
        f.reset(orientation: wrong);
        // Mahony with kp=1 needs several time constants; run 15 s.
        const level = Vector3(0, 0, g);
        expect(tiltError(f.orientation, level), greaterThan(1.0));
        for (var i = 0; i < 3000; i++) {
          f.update(gyro: Vector3.zero, accel: level, dt: 0.005);
        }
        expect(tiltError(f.orientation, level), lessThan(0.02));
      });

      test('zero accel gives no NaN and keeps integrating gyro', () {
        f.update(gyro: Vector3.zero, accel: const Vector3(0, 0, g), dt: 0.01);
        for (var i = 0; i < 100; i++) {
          f.update(gyro: const Vector3(0, 0, 1), accel: Vector3.zero, dt: 0.01);
        }
        final q = f.orientation;
        expect(q.isFinite, isTrue);
        expect(q.norm, closeTo(1, 1e-9));
        expect(q.toEuler().yaw, closeTo(1.0, 0.01));
        expect(f.skippedUpdates, 0);
      });

      test(
        'zero accel as the very first sample does not initialize or NaN',
        () {
          f.update(gyro: Vector3.zero, accel: Vector3.zero, dt: 0.01);
          expect(f.orientation.isFinite, isTrue);
          expect(f.isInitialized, isFalse);
        },
      );

      test('bad dt is skipped and counted', () {
        const level = Vector3(0, 0, g);
        f.update(gyro: Vector3.zero, accel: level, dt: 0.01); // seeds
        final before = f.orientation;
        const spin = Vector3(5, 5, 5);
        for (final dt in [0.0, -0.01, 0.5, double.nan, double.infinity]) {
          f.update(gyro: spin, accel: level, dt: dt);
        }
        expect(f.skippedUpdates, 5);
        expect(f.orientation.angleTo(before), 0);
        f.update(gyro: spin, accel: level, dt: 0.01);
        expect(f.skippedUpdates, 5);
        expect(f.orientation.angleTo(before), greaterThan(0));
      });

      test('maxDt is configurable', () {
        final custom = MadgwickFilter(maxDt: 0.5);
        custom.update(
          gyro: Vector3.zero,
          accel: const Vector3(0, 0, g),
          dt: 0.01,
        );
        custom.update(
          gyro: const Vector3(0, 0, 1),
          accel: const Vector3(0, 0, g),
          dt: 0.3,
        );
        expect(custom.skippedUpdates, 0);
      });

      test('non-finite input is skipped and counted', () {
        f.update(gyro: Vector3.zero, accel: const Vector3(0, 0, g), dt: 0.01);
        f.update(
          gyro: const Vector3(double.nan, 0, 0),
          accel: const Vector3(0, 0, g),
          dt: 0.01,
        );
        expect(f.skippedUpdates, 1);
        expect(f.orientation.isFinite, isTrue);
      });

      test('resetYaw zeroes heading but keeps tilt', () {
        final pose = Quaternion.fromEuler(yaw: 0.9, pitch: 0.3, roll: -0.4);
        f.reset(orientation: pose);
        f.resetYaw();
        final e = f.orientation.toEuler();
        expect(e.yaw, closeTo(0, 1e-9));
        expect(e.pitch, closeTo(0.3, 1e-9));
        expect(e.roll, closeTo(-0.4, 1e-9));
        expect(f.orientation.norm, closeTo(1, 1e-12));
      });

      test('resetYaw is stable near pitch = +/-90 degrees', () {
        final pose = Quaternion.fromEuler(
          yaw: 1.1,
          pitch: math.pi / 2,
          roll: 0,
        );
        f.reset(orientation: pose);
        f.resetYaw();
        expect(f.orientation.isFinite, isTrue);
        expect(f.orientation.norm, closeTo(1, 1e-12));
        // The gravity direction must survive removing the heading.
        final before = pose.rotate(const Vector3(0, 0, 1));
        final after = f.orientation.rotate(const Vector3(0, 0, 1));
        expect(after.dot(before), closeTo(1, 1e-9));
      });

      test('stays normalized over 100000 updates', () {
        var seed = 12345;
        double rnd() {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          return seed / 0x7fffffff - 0.5;
        }

        f.update(gyro: Vector3.zero, accel: const Vector3(0, 0, g), dt: 0.005);
        for (var i = 0; i < 100000; i++) {
          f.update(
            gyro: Vector3(rnd() * 8, rnd() * 8, rnd() * 8),
            accel: Vector3(rnd() * 40, rnd() * 40, g + rnd() * 40),
            dt: 0.005,
          );
        }
        expect(f.orientation.isFinite, isTrue);
        expect(f.orientation.norm, closeTo(1, 1e-9));
      });
    });
  }

  group('Mahony integral term', () {
    test('reduces the effect of a constant gyro bias', () {
      const bias = Vector3(0.05, -0.03, 0);
      const level = Vector3(0, 0, g);

      double finalTilt(MahonyFilter f) {
        f.update(gyro: Vector3.zero, accel: level, dt: 0.005);
        for (var i = 0; i < 12000; i++) {
          // 60 s stationary with biased gyro.
          f.update(gyro: bias, accel: level, dt: 0.005);
        }
        return tiltError(f.orientation, level);
      }

      final noKi = MahonyFilter(kp: 1, ki: 0);
      final withKi = MahonyFilter(kp: 1, ki: 0.5);
      final errNo = finalTilt(noKi);
      final errKi = finalTilt(withKi);

      // Without Ki the steady error is about |bias| / kp = 0.058 rad.
      expect(errNo, greaterThan(0.04));
      expect(errKi, lessThan(errNo / 10));
      expect(withKi.gyroBiasEstimate.x, closeTo(0.05, 0.005));
      expect(withKi.gyroBiasEstimate.y, closeTo(-0.03, 0.005));
    });

    test('reset clears the integral', () {
      final f = MahonyFilter(kp: 1, ki: 0.5);
      f.update(gyro: Vector3.zero, accel: const Vector3(0, 0, g), dt: 0.01);
      for (var i = 0; i < 500; i++) {
        f.update(
          gyro: const Vector3(0.1, 0, 0),
          accel: const Vector3(0, 0, g),
          dt: 0.01,
        );
      }
      expect(f.gyroBiasEstimate.x, isNot(0));
      f.reset();
      expect(f.gyroBiasEstimate.length, 0);
    });
  });
}
