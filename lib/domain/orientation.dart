import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Frame convention: X right, Y up, Z toward the viewer.
/// Euler order: yaw about Y, then pitch about X, then roll about Z
/// (q = qYaw * qPitch * qRoll). Angles in radians.
class Euler {
  const Euler(this.yaw, this.pitch, this.roll);

  final double yaw;
  final double pitch;
  final double roll;

  double get yawDeg => yaw * radians2Degrees;
  double get pitchDeg => pitch * radians2Degrees;
  double get rollDeg => roll * radians2Degrees;
}

Quaternion quaternionFromEuler(double yaw, double pitch, double roll) =>
    Quaternion.axisAngle(Vector3(0, 1, 0), yaw) *
    Quaternion.axisAngle(Vector3(1, 0, 0), pitch) *
    Quaternion.axisAngle(Vector3(0, 0, 1), roll);

Euler eulerFromQuaternion(Quaternion q) {
  final m = q.normalized().asRotationMatrix();
  final pitch = math.asin((-m.entry(1, 2)).clamp(-1.0, 1.0));
  final yaw = math.atan2(m.entry(0, 2), m.entry(2, 2));
  final roll = math.atan2(m.entry(1, 0), m.entry(1, 1));
  return Euler(yaw, pitch, roll);
}

/// Rotates [v] by [q] (active rotation, q v q*). vector_math's
/// `Quaternion.rotated` applies the inverse, so do not use it.
Vector3 rotateVector(Quaternion q, Vector3 v) =>
    q.normalized().asRotationMatrix().transformed(v);

/// Returns [q] with [yawOffset] removed about the world Y axis.
Quaternion removeYaw(Quaternion q, double yawOffset) =>
    Quaternion.axisAngle(Vector3(0, 1, 0), -yawOffset) * q;
