import 'orientation_filter.dart';
import 'quaternion.dart';
import 'vector3.dart';

/// Madgwick gradient-descent filter, 6-axis (gyro + accel) variant.
///
/// [beta] trades gyro trust against gravity correction (rad/s). Larger values
/// pull toward gravity faster but pass more linear-acceleration noise;
/// 0.02-0.1 is typical at 100-200 Hz. See [OrientationFilter] for frame and
/// units.
class MadgwickFilter extends OrientationFilterBase {
  /// Gradient step gain. Mutable so it can be tuned live.
  double beta;

  MadgwickFilter({
    this.beta = 0.05,
    super.maxDt,
    super.minAccelNorm,
  });

  @override
  void step(Vector3 gyro, Vector3? a, double dt) {
    final q0 = w, q1 = x, q2 = y, q3 = z;

    // Rate of change from the gyro: 0.5 * q (x) (0, gyro).
    var d0 = 0.5 * (-q1 * gyro.x - q2 * gyro.y - q3 * gyro.z);
    var d1 = 0.5 * (q0 * gyro.x + q2 * gyro.z - q3 * gyro.y);
    var d2 = 0.5 * (q0 * gyro.y - q1 * gyro.z + q3 * gyro.x);
    var d3 = 0.5 * (q0 * gyro.z + q1 * gyro.y - q2 * gyro.x);

    if (a != null) {
      // Gradient of |predicted gravity - a|^2 with respect to q.
      final s = Quaternion(
        4 * q0 * q2 * q2 + 2 * q2 * a.x + 4 * q0 * q1 * q1 - 2 * q1 * a.y,
        4 * q1 * q3 * q3 -
            2 * q3 * a.x +
            4 * q0 * q0 * q1 -
            2 * q0 * a.y -
            4 * q1 +
            8 * q1 * q1 * q1 +
            8 * q1 * q2 * q2 +
            4 * q1 * a.z,
        4 * q0 * q0 * q2 +
            2 * q0 * a.x +
            4 * q2 * q3 * q3 -
            2 * q3 * a.y -
            4 * q2 +
            8 * q2 * q1 * q1 +
            8 * q2 * q2 * q2 +
            4 * q2 * a.z,
        4 * q1 * q1 * q3 - 2 * q1 * a.x + 4 * q2 * q2 * q3 - 2 * q2 * a.y,
      );
      final n = s.norm;
      if (n > 1e-12) {
        d0 -= beta * s.w / n;
        d1 -= beta * s.x / n;
        d2 -= beta * s.y / n;
        d3 -= beta * s.z / n;
      }
    }

    setState(q0 + d0 * dt, q1 + d1 * dt, q2 + d2 * dt, q3 + d3 * dt);
  }
}
