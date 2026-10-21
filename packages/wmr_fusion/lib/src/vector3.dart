import 'dart:math' as math;

/// Minimal 3-vector in a right-handed frame.
class Vector3 {
  final double x;
  final double y;
  final double z;

  const Vector3(this.x, this.y, this.z);

  static const Vector3 zero = Vector3(0, 0, 0);

  double get length => math.sqrt(x * x + y * y + z * z);

  bool get isFinite => x.isFinite && y.isFinite && z.isFinite;

  /// Unit vector in the same direction, or [zero] if the length is 0 or not finite.
  Vector3 normalized() {
    final l = length;
    if (!(l > 0) || !l.isFinite) return zero;
    return Vector3(x / l, y / l, z / l);
  }

  double dot(Vector3 o) => x * o.x + y * o.y + z * o.z;

  Vector3 cross(Vector3 o) =>
      Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  Vector3 operator +(Vector3 o) => Vector3(x + o.x, y + o.y, z + o.z);
  Vector3 operator -(Vector3 o) => Vector3(x - o.x, y - o.y, z - o.z);
  Vector3 operator *(double s) => Vector3(x * s, y * s, z * s);
  Vector3 operator -() => Vector3(-x, -y, -z);

  /// Angle between this vector and [o] in radians (0 if either is zero).
  double angleTo(Vector3 o) {
    final d = length * o.length;
    if (!(d > 0)) return 0;
    return math.acos((dot(o) / d).clamp(-1.0, 1.0));
  }

  @override
  String toString() => 'Vector3($x, $y, $z)';
}
