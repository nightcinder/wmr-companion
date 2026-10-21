import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion/domain/orientation.dart';
import 'package:wmr_companion/domain/synthetic_motion.dart';

void main() {
  test('Euler round trip', () {
    for (final (y, p, r) in [
      (0.0, 0.0, 0.0),
      (0.5, -0.3, 1.2),
      (-2.0, 1.0, -0.7),
      (3.0, 0.2, 2.9),
    ]) {
      final e = eulerFromQuaternion(quaternionFromEuler(y, p, r));
      expect(e.yaw, closeTo(y, 1e-9));
      expect(e.pitch, closeTo(p, 1e-9));
      expect(e.roll, closeTo(r, 1e-9));
    }
  });

  test('yaw rotates about Y: +X goes to -Z for +90 deg', () {
    final v = rotateVector(
      quaternionFromEuler(radians(90), 0, 0),
      Vector3(1, 0, 0),
    );
    expect(v.x, closeTo(0, 1e-9));
    expect(v.z, closeTo(-1, 1e-9));
  });

  test('removeYaw zeroes yaw and keeps pitch and roll', () {
    final q = quaternionFromEuler(1.1, 0.4, -0.6);
    final e = eulerFromQuaternion(removeYaw(q, eulerFromQuaternion(q).yaw));
    expect(e.yaw, closeTo(0, 1e-9));
    expect(e.pitch, closeTo(0.4, 1e-9));
    expect(e.roll, closeTo(-0.6, 1e-9));
  });

  test('synthetic motion is unit length and deterministic', () {
    const m = SyntheticMotion();
    final a = m.at(const Duration(milliseconds: 1234));
    final b = m.at(const Duration(milliseconds: 1234));
    expect(a.length, closeTo(1, 1e-9));
    expect(a.storage, b.storage);
  });
}
