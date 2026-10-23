import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_core/domain/axis_mapping.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';

import 'sim.dart';

/// Default table, written out by hand: view axis a sensor axis maps to.
/// sensor X -> +view Y, sensor Y -> -view X, sensor Z -> +view Z.
final List<vm.Vector3> defaultViewAxisOfSensor = [
  vm.Vector3(0, 1, 0),
  vm.Vector3(-1, 0, 0),
  vm.Vector3(0, 0, 1),
];

List<double> unit(int axis) => [
  for (var k = 0; k < 3; k++) k == axis ? 1.0 : 0.0,
];

void expectVec(vm.Vector3 got, vm.Vector3 want) {
  expect(got.x, closeTo(want.x, 1e-9), reason: '$got vs $want');
  expect(got.y, closeTo(want.y, 1e-9), reason: '$got vs $want');
  expect(got.z, closeTo(want.z, 1e-9), reason: '$got vs $want');
}

/// |dot| of two quaternions: 1 means the same rotation.
double same(vm.Quaternion a, vm.Quaternion b) =>
    (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w).abs();

void main() {
  group('default table', () {
    const m = AxisMapping.defaultMapping;

    test('is a proper rotation (determinant +1)', () {
      final cols = [for (var k = 0; k < 3; k++) m.gyroToView(unit(k))];
      final det = cols[0].dot(cols[1].cross(cols[2]));
      expect(det, closeTo(1, 1e-12));
    });

    test('maps a unit rotation about each sensor axis', () {
      for (var k = 0; k < 3; k++) {
        expectVec(m.gyroToView(unit(k)), defaultViewAxisOfSensor[k]);
        expectVec(m.accelToView(unit(k)), defaultViewAxisOfSensor[k]);
      }
    });

    test('gravity at rest reads up on view Y when sensor X points up', () {
      expectVec(m.accelToView([10, 0, 0]), vm.Vector3(0, 10, 0));
    });

    test('describes itself', () => expect(m.toString(), 'X=-y Y=+x Z=+z'));
  });

  group('flips, vector level', () {
    for (var i = 0; i < 3; i++) {
      test('flip on view axis $i negates it for gyro and accel', () {
        final m = AxisMapping.defaultMapping.withFlip(i, true);
        for (var k = 0; k < 3; k++) {
          final want = defaultViewAxisOfSensor[k].clone();
          want[i] = -want[i];
          expectVec(m.gyroToView(unit(k)), want);
          expectVec(m.accelToView(unit(k)), want);
        }
      });

      test('gyroFlip on view axis $i negates the gyro only', () {
        final m = AxisMapping.defaultMapping.withGyroFlip(i, true);
        for (var k = 0; k < 3; k++) {
          final want = defaultViewAxisOfSensor[k].clone();
          expectVec(m.accelToView(unit(k)), want);
          want[i] = -want[i];
          expectVec(m.gyroToView(unit(k)), want);
        }
      });
    }

    test('a flip can be switched off again', () {
      final m = AxisMapping.defaultMapping.withFlip(1, true).withFlip(1, false);
      expectVec(m.gyroToView(unit(0)), defaultViewAxisOfSensor[0]);
    });
  });

  group('frame conversion', () {
    test('view axes land on the filter axes x = X, y = -Z, z = Y', () {
      final f = viewToFilter(vm.Vector3(1, 2, 3));
      expect([f.x, f.y, f.z], [1, -3, 2]);
    });
  });

  group('known rotation through the whole pipeline', () {
    const rate = math.pi / 2; // 90 degrees in the 1 s turn

    vm.Quaternion run(AxisMapping mapping, int sensorAxis) {
      final p = HandPipeline(mapping: mapping);
      DecodedSample? last;
      for (final r in sensorTurn(axis: sensorAxis, rate: rate)) {
        last = p.add(r, 0);
      }
      return last!.orientation;
    }

    for (var k = 0; k < 3; k++) {
      test(
        'default table: sensor axis $k gives +90 deg about its view axis',
        () {
          final q = run(AxisMapping.defaultMapping, k);
          final want = vm.Quaternion.axisAngle(
            defaultViewAxisOfSensor[k],
            rate,
          );
          expect(same(q, want), greaterThan(0.999), reason: '$q vs $want');
        },
      );

      test('gyroFlip on the mapped view axis reverses sensor axis $k', () {
        final viewAxis = [1, 0, 2][k]; // sensor X->Y, Y->X, Z->Z
        final m = AxisMapping.defaultMapping.withGyroFlip(viewAxis, true);
        final q = run(m, k);
        final want = vm.Quaternion.axisAngle(defaultViewAxisOfSensor[k], -rate);
        // Gyro and accel now disagree for tilting axes, so allow the
        // accelerometer to pull the result part of the way.
        expect(same(q, want), greaterThan(k == 0 ? 0.999 : 0.9));
      });
    }

    test('rest orientation is level: sensor X up gives the identity', () {
      final q = run(AxisMapping.defaultMapping, 0).clone();
      final still = HandPipeline();
      DecodedSample? s;
      for (final r in sensorTurn(axis: 0, rate: 0)) {
        s = still.add(r, 0);
      }
      expect(
        same(s!.orientation, vm.Quaternion.identity()),
        greaterThan(0.999),
      );
      expect(q.length, closeTo(1, 1e-9));
    });
  });
}
