import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

void main() {
  test('identity composes without changing a pose', () {
    final pose = Pose(
      translation: Vector3(1, 2, 3),
      rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.4),
    );

    final result = Pose.identity * pose;

    expect(result.translation, vectorMoreOrLessEquals(pose.translation));
    expect(result.rotation, quaternionMoreOrLessEquals(pose.rotation));
  });

  test('composition applies the right operand first', () {
    final rotate = Pose(
      translation: Vector3.zero(),
      rotation: Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2),
    );
    final translate = Pose(
      translation: Vector3(0, 0, -1),
      rotation: Quaternion.identity(),
    );

    final result = rotate * translate;

    expect(result.translation, vectorMoreOrLessEquals(Vector3(-1, 0, 0)));
  });

  test('inverse undoes a transform', () {
    final pose = Pose(
      translation: Vector3(-0.5, 1.7, 0.25),
      rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.8),
    );
    final point = Vector3(0.3, -0.2, -1.4);

    final roundTrip = pose.inverse().transformPoint(pose.transformPoint(point));
    final identity = pose * pose.inverse();

    expect(roundTrip, vectorMoreOrLessEquals(point, epsilon: 1e-9));
    expect(identity.translation, vectorMoreOrLessEquals(Vector3.zero()));
    expect(
      identity.rotation,
      quaternionMoreOrLessEquals(Quaternion.identity()),
    );
  });

  test('JSON uses translation [x,y,z] and quaternion [x,y,z,w]', () {
    final pose = Pose(
      translation: Vector3(1, 2, 3),
      rotation: Quaternion(0.5, 0.5, 0.5, 0.5),
    );

    final json = pose.toJson();
    expect(json['t'], [1.0, 2.0, 3.0]);
    expect(json['q'], [0.5, 0.5, 0.5, 0.5]);
    expect(Pose.fromJson(json), pose);
  });

  test('a malformed pose is rejected', () {
    expect(
      () => Pose.fromJson({
        't': [1, 2],
        'q': [0, 0, 0, 1],
      }),
      throwsFormatException,
    );
    expect(
      () => Pose.fromJson({
        't': [1, 2, 3],
        'q': ['x', 0, 0, 1],
      }),
      throwsFormatException,
    );
    expect(() => Pose.fromJson('not a pose'), throwsFormatException);
  });
}

Matcher vectorMoreOrLessEquals(Vector3 expected, {double epsilon = 1e-6}) =>
    predicate<Vector3>(
      (actual) =>
          (actual.x - expected.x).abs() <= epsilon &&
          (actual.y - expected.y).abs() <= epsilon &&
          (actual.z - expected.z).abs() <= epsilon,
      'is within $epsilon of $expected',
    );

Matcher quaternionMoreOrLessEquals(
  Quaternion expected, {
  double epsilon = 1e-6,
}) => predicate<Quaternion>(
  (actual) =>
      (actual.x - expected.x).abs() <= epsilon &&
      (actual.y - expected.y).abs() <= epsilon &&
      (actual.z - expected.z).abs() <= epsilon &&
      (actual.w - expected.w).abs() <= epsilon,
  'is within $epsilon of $expected',
);
