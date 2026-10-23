import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/domain/imu_calibration.dart';
import 'package:wmr_core/domain/orientation.dart';
import 'package:wmr_core/domain/tick_timer.dart';
import 'package:wmr_core/protocol/config_decode.dart';
import 'package:wmr_core/protocol/decoded_record.dart';

import 'sim.dart';

/// Stationary samples with a constant gyro offset.
Iterable<int> still(
  HandPipeline p,
  int from,
  int count, {
  List<double>? gyro,
}) sync* {
  for (var i = 0; i < count; i++) {
    final ticks = from + i * nominalPeriodTicks;
    p.add(record(ticks: ticks, gyro: gyro ?? const [0, 0, 0]), 0);
    yield ticks;
  }
}

double yawDeg(HandPipeline p) => eulerFromQuaternion(p.orientation).yawDeg;

void main() {
  test('gyro bias is estimated in the first second and stops the drift', () {
    final p = HandPipeline();
    const bias = [0.02, -0.03, 0.04];
    final ticks = still(p, 0, 600, gyro: bias).last; // ~3.5 s
    expect(p.bias.calibrated, isTrue);
    expect(p.bias.bias[0], closeTo(0.02, 1e-6));
    // Sensor X is up: bias[0] is the yaw rate, would be ~4 deg over 3.5 s.
    // The first second runs with the bias still unknown (about 1.1 deg here);
    // the remaining 2.5 s add nothing.
    expect(yawDeg(p).abs(), lessThan(1.5));
    expect(ticks, greaterThan(0));
  });

  test('without calibration the same bias drifts the yaw', () {
    final p = HandPipeline();
    // Never stationary-looking: noisy accel magnitude keeps it uncalibrated.
    for (var i = 0; i < 600; i++) {
      p.add(
        record(
          ticks: i * nominalPeriodTicks,
          gyro: const [0.2, 0, 0],
          accel: [gravity + (i.isEven ? 1.5 : -1.5), 0, 0],
        ),
        0,
      );
    }
    expect(p.bias.calibrated, isFalse);
    expect(yawDeg(p).abs(), greaterThan(10));
  });

  test('recalibrate starts over', () {
    final p = HandPipeline();
    still(p, 0, 300, gyro: const [0.02, 0, 0]).last;
    expect(p.bias.calibrated, isTrue);
    p.recalibrate();
    expect(p.bias.calibrated, isFalse);
    still(p, 400 * nominalPeriodTicks, 300, gyro: const [-0.05, 0, 0]).last;
    expect(p.bias.bias[0], closeTo(-0.05, 1e-6));
  });

  test('a dt above 100 ms skips the filter step and is counted', () {
    final p = HandPipeline();
    still(p, 0, 50).last;
    final before = p.samples;
    // 300 ms gap: same on the tick and the receive clock, no discontinuity.
    final s = p.add(
      record(ticks: 49 * nominalPeriodTicks + 3000000, gyro: const [0, 0, 5]),
      0,
    );
    expect(s.step.kind, TickStepKind.step);
    expect(s.step.dtSeconds, closeTo(0.3, 0.001));
    expect(s.fused, isFalse);
    expect(p.largeDtSkips, 1);
    expect(p.samples, before + 1);
    expect(yawDeg(p).abs(), lessThan(0.5)); // the 5 rad/s was not integrated
  });

  test(
    'a dt of a few periods (lost reports) is integrated with the real dt',
    () {
      final p = HandPipeline();
      still(p, 0, 400).last; // calibrate
      final q0 = p.orientation.clone();
      // 40 ms gap carrying 1 rad/s about the vertical axis.
      final s = p.add(
        record(ticks: 399 * nominalPeriodTicks + 400000, gyro: const [1, 0, 0]),
        0,
      );
      expect(s.fused, isTrue);
      expect(s.step.dtSeconds, closeTo(0.04, 1e-6));
      final dyaw =
          (eulerFromQuaternion(s.orientation).yaw - eulerFromQuaternion(q0).yaw)
              .abs();
      expect(dyaw, closeTo(s.step.dtSeconds, 0.002));
    },
  );

  test('a tick discontinuity keeps the orientation and does not integrate', () {
    final p = HandPipeline();
    still(p, 0, 400).last;
    final q = p.orientation.clone();
    // Ticks jump back by a lot while the ESP32 clock moves normally.
    final s = p.add(
      record(
        ticks: 100,
        rxTimeUs: 1000000 + 400 * nominalPeriodTicks ~/ 10,
        gyro: const [3, 0, 0],
      ),
      0,
    );
    expect(s.step.kind, TickStepKind.discontinuity);
    expect(s.fused, isFalse);
    expect((p.orientation.x - q.x).abs(), lessThan(1e-9));
    expect((p.orientation.y - q.y).abs(), lessThan(1e-9));
  });

  test('non-finite input is counted and ignored', () {
    final p = HandPipeline();
    still(p, 0, 10).last;
    final s = p.add(
      record(ticks: 10 * nominalPeriodTicks, gyro: const [double.nan, 0, 0]),
      0,
    );
    expect(s.fused, isFalse);
    expect(p.nonFiniteSkips, 1);
    expect(p.orientation.length, closeTo(1, 1e-9));
  });

  test('Mahony can be selected and keeps the orientation', () {
    final p = HandPipeline();
    for (final r in sensorTurn(
      axis: 1,
      rate: 1.0,
      stillSeconds: 1.2,
      turnSeconds: 0.5,
    )) {
      p.add(r, 0);
    }
    final q = p.orientation.clone();
    p.setFilter(FilterKind.mahony);
    expect(p.kind, FilterKind.mahony);
    final d =
        (p.orientation.x * q.x +
                p.orientation.y * q.y +
                p.orientation.z * q.z +
                p.orientation.w * q.w)
            .abs();
    expect(d, greaterThan(0.9999));
    for (final r in sensorTurn(
      axis: 0,
      rate: 0,
      stillSeconds: 0.5,
      turnSeconds: 0,
      startTicks: 5000000,
    )) {
      p.add(r, 0);
    }
    expect(p.orientation.length, closeTo(1, 1e-9));
  });

  test('resetYaw zeroes heading and keeps tilt', () {
    final p = HandPipeline();
    for (final r in sensorTurn(
      axis: 0,
      rate: 1.0,
      stillSeconds: 1.2,
      turnSeconds: 1.0,
    )) {
      p.add(r, 0);
    }
    expect(yawDeg(p).abs(), greaterThan(30));
    p.resetYaw();
    expect(yawDeg(p).abs(), lessThan(0.01));
  });

  group('live filter tuning', () {
    double angleBetween(vm.Quaternion a, vm.Quaternion b) {
      final d = (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w).abs().clamp(
        0.0,
        1.0,
      );
      return 2 * math.acos(d);
    }

    test('changing beta reaches the active Madgwick filter', () {
      HandPipeline run(double beta) {
        final p = HandPipeline();
        // Settle the tilt and the runtime bias first.
        for (var i = 0; i < 200; i++) {
          p.add(record(ticks: i * nominalPeriodTicks), 0);
        }
        p.beta = beta;
        // A sustained roll rate against level gravity: more beta pulls the
        // estimate back toward the accelerometer.
        for (var i = 200; i < 500; i++) {
          p.add(
            record(ticks: i * nominalPeriodTicks, gyro: const [0, 1.5, 0]),
            0,
          );
        }
        return p;
      }

      expect(HandPipeline().beta, 0.05);
      expect(
        angleBetween(run(0.01).orientation, run(0.2).orientation),
        greaterThan(0.01),
      );
    });

    test('Mahony gains reach the filter and survive a switch', () {
      final p = HandPipeline();
      p.mahonyKp = 3.0;
      p.mahonyKi = 0.25;
      expect(p.tuning, const FilterTuning(mahonyKp: 3.0, mahonyKi: 0.25));
      p.setFilter(FilterKind.mahony);
      expect(p.kind, FilterKind.mahony);
      expect(p.mahonyKp, 3.0);
      expect(p.mahonyKi, 0.25);
      p.setFilter(FilterKind.madgwick);
      expect(p.beta, 0.05);
      expect(p.mahonyKp, 3.0);
    });
  });

  test('view-frame output is a unit quaternion', () {
    final p = HandPipeline();
    for (final r in sensorTurn(axis: 2, rate: 2.0)) {
      p.add(r, 0);
    }
    final q = p.orientation;
    expect(q, isA<vm.Quaternion>());
    expect(q.length, closeTo(1, 1e-9));
  });

  group('FF13 calibration', () {
    test('identity calibration leaves the fused orientation unchanged', () {
      final off = HandPipeline();
      final on = HandPipeline()..calibration = _calibration();
      for (final r in sensorTurn(axis: 2, rate: 1.5)) {
        off.add(r, 0);
        on.add(r, 0);
      }
      _expectSameOrientation(on.orientation, off.orientation);
    });

    test('a 90 deg Rt turns the motion from view roll to view pitch', () {
      // Rt = +90 deg about sensor X. The calibration applies its inverse
      // (-90 deg about X), so a sensor Z rotation (view roll with the default
      // axis map) becomes a rotation about sensor Y (view pitch). The accel
      // in sensorTurn is consistent with that motion, so the filter can
      // follow; the point is that the calibrated and uncalibrated paths see
      // different, but each internally consistent, body motions.
      final off = HandPipeline();
      final on = HandPipeline()
        ..calibration = _calibration(
          rotation: const [1, 0, 0, 0, 0, -1, 0, 1, 0],
        );
      for (final r in sensorTurn(
        axis: 2,
        rate: math.pi / 2,
        stillSeconds: 1.2,
        turnSeconds: 1.0,
      )) {
        off.add(r, 0);
        on.add(r, 0);
      }
      final eOff = eulerFromQuaternion(off.orientation);
      final eOn = eulerFromQuaternion(on.orientation);
      expect(eOff.rollDeg.abs(), greaterThan(60));
      expect(eOn.pitchDeg.abs(), greaterThan(60));
      expect(eOn.rollDeg.abs(), lessThan(20));
    });

    test('CALIBRATED-flagged records are not calibrated twice', () {
      final off = HandPipeline();
      final on = HandPipeline()
        ..calibration = _calibration(
          rotation: const [0, -1, 0, 1, 0, 0, 0, 0, 1],
          bias: const [0.1, 0.2, 0.3],
        );
      final records = sensorTurn(
        axis: 0,
        rate: 1.0,
        flags: wmrDecodedFlagCalibrated,
      ).toList();
      for (final r in records) {
        off.add(r, 0);
        on.add(r, 0);
      }
      expect(on.calibratedFlagged, records.length);
      _expectSameOrientation(on.orientation, off.orientation);
    });

    test('clearing the calibration (switch off) is the old path', () {
      final off = HandPipeline();
      final on = HandPipeline()
        ..calibration = _calibration(
          rotation: const [0, -1, 0, 1, 0, 0, 0, 0, 1],
        );
      on.calibration = null;
      expect(on.calibration, isNull);
      for (final r in sensorTurn(axis: 1, rate: 1.0)) {
        off.add(r, 0);
        on.add(r, 0);
      }
      _expectSameOrientation(on.orientation, off.orientation);
    });

    test('changing the calibration restarts the runtime gyro bias', () {
      final p = HandPipeline();
      still(p, 0, 600).last;
      expect(p.bias.calibrated, isTrue);
      p.calibration = _calibration();
      expect(p.bias.calibrated, isFalse);
    });
  });
}

ImuCalibration _calibration({
  List<double> rotation = const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  List<double> mix = const [1, 0, 0, 0, 1, 0, 0, 0, 1],
  List<double> bias = const [0, 0, 0],
}) => ImuCalibration.fromSensors(
  accel: _sensor(InertialSensorType.accelerometer, rotation, mix, bias),
  gyro: _sensor(InertialSensorType.gyro, rotation, mix, bias),
);

InertialSensorCalibration _sensor(
  InertialSensorType type,
  List<double> rotation,
  List<double> mix,
  List<double> bias,
) => InertialSensorCalibration(
  type: type,
  typeName: type == InertialSensorType.gyro
      ? 'CALIBRATION_InertialSensorType_Gyro'
      : 'CALIBRATION_InertialSensorType_Accelerometer',
  rotation: rotation,
  translation: const [0, 0, 0],
  mixMatrix: mix,
  bias: bias,
  biasUncertainty: const [0, 0, 0],
  noise: const [0, 0, 0],
);

void _expectSameOrientation(vm.Quaternion a, vm.Quaternion b) {
  final d = (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w).abs();
  expect(d, greaterThan(1 - 1e-9));
}
