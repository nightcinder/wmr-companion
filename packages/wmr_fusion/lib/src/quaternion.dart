import 'dart:math' as math;

import 'vector3.dart';

/// Quaternion (w, x, y, z), Hamilton convention.
///
/// As a filter output it is a unit quaternion rotating body-frame vectors
/// into the world frame (`q.rotate(vBody) == vWorld`). World is right-handed
/// with +z up; body is the sensor frame.
class Quaternion {
  final double w;
  final double x;
  final double y;
  final double z;

  const Quaternion(this.w, this.x, this.y, this.z);

  static const Quaternion identity = Quaternion(1, 0, 0, 0);

  /// Rotation of [angle] radians about [axis] (need not be normalized).
  factory Quaternion.fromAxisAngle(Vector3 axis, double angle) {
    final a = axis.normalized();
    final s = math.sin(angle / 2);
    return Quaternion(math.cos(angle / 2), a.x * s, a.y * s, a.z * s);
  }

  /// Intrinsic Z-Y-X (yaw, pitch, roll) angles in radians: yaw about z, then
  /// pitch about the new y, then roll about the new x.
  factory Quaternion.fromEuler({
    required double yaw,
    required double pitch,
    required double roll,
  }) {
    final cy = math.cos(yaw / 2), sy = math.sin(yaw / 2);
    final cp = math.cos(pitch / 2), sp = math.sin(pitch / 2);
    final cr = math.cos(roll / 2), sr = math.sin(roll / 2);
    return Quaternion(
      cr * cp * cy + sr * sp * sy,
      sr * cp * cy - cr * sp * sy,
      cr * sp * cy + sr * cp * sy,
      cr * cp * sy - sr * sp * cy,
    );
  }

  double get norm => math.sqrt(w * w + x * x + y * y + z * z);

  bool get isFinite => w.isFinite && x.isFinite && y.isFinite && z.isFinite;

  /// Unit quaternion, or [identity] if the norm is 0 or not finite.
  Quaternion normalized() {
    final n = norm;
    if (!(n > 0) || !n.isFinite) return identity;
    return Quaternion(w / n, x / n, y / n, z / n);
  }

  Quaternion conjugate() => Quaternion(w, -x, -y, -z);

  /// Hamilton product `this * o` (apply [o] first, then this).
  Quaternion operator *(Quaternion o) => Quaternion(
        w * o.w - x * o.x - y * o.y - z * o.z,
        w * o.x + x * o.w + y * o.z - z * o.y,
        w * o.y - x * o.z + y * o.w + z * o.x,
        w * o.z + x * o.y - y * o.x + z * o.w,
      );

  /// Rotates [v] by this (unit) quaternion.
  Vector3 rotate(Vector3 v) {
    final u = Vector3(x, y, z);
    final t = u.cross(v) * 2;
    return v + t * w + u.cross(t);
  }

  /// Intrinsic Z-Y-X angles in radians. Pitch is in [-pi/2, pi/2]; yaw is
  /// arbitrary (but consistent) at gimbal lock.
  ({double yaw, double pitch, double roll}) toEuler() {
    final sinp = (2 * (w * y - z * x)).clamp(-1.0, 1.0);
    return (
      yaw: math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)),
      pitch: math.asin(sinp),
      roll: math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)),
    );
  }

  /// Smallest rotation angle in radians between this and [o].
  double angleTo(Quaternion o) {
    final d = (w * o.w + x * o.x + y * o.y + z * o.z).abs().clamp(0.0, 1.0);
    return 2 * math.acos(d);
  }

  @override
  String toString() => 'Quaternion($w, $x, $y, $z)';
}
