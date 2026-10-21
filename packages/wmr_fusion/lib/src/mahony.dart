import 'orientation_filter.dart';
import 'vector3.dart';

/// Mahony complementary filter, 6-axis (gyro + accel) variant.
///
/// [kp] is the proportional gain (1/s) pulling toward gravity; [ki] is the
/// integral gain (1/s^2) that estimates a constant gyro bias, readable as
/// [gyroBiasEstimate]. Set [ki] to 0 to disable the bias term. See
/// [OrientationFilter] for frame and units.
class MahonyFilter extends OrientationFilterBase {
  /// Proportional gain. Mutable so it can be tuned live.
  double kp;

  /// Integral gain. Mutable so it can be tuned live.
  double ki;

  /// Limit on each axis of the integral term (rad/s), to bound windup.
  final double maxBias;

  Vector3 _integral = Vector3.zero;

  MahonyFilter({
    this.kp = 1.0,
    this.ki = 0.05,
    this.maxBias = 0.5,
    super.maxDt,
    super.minAccelNorm,
  });

  /// Gyro bias (rad/s) the filter currently believes in: the gyro reads
  /// true rate plus this.
  Vector3 get gyroBiasEstimate => -_integral;

  @override
  void onReset() => _integral = Vector3.zero;

  @override
  void step(Vector3 gyro, Vector3? a, double dt) {
    if (a != null) {
      // Gravity direction in the body frame predicted by the current state.
      final v = Vector3(
        2 * (x * z - w * y),
        2 * (w * x + y * z),
        w * w - x * x - y * y + z * z,
      );
      final e = a.cross(v);
      if (ki > 0) {
        _integral = Vector3(
          (_integral.x + ki * e.x * dt).clamp(-maxBias, maxBias),
          (_integral.y + ki * e.y * dt).clamp(-maxBias, maxBias),
          (_integral.z + ki * e.z * dt).clamp(-maxBias, maxBias),
        );
      }
      final q = integrateRate(w, x, y, z, gyro + e * kp + _integral, dt);
      setState(q.w, q.x, q.y, q.z);
    } else {
      final q = integrateRate(w, x, y, z, gyro + _integral, dt);
      setState(q.w, q.x, q.y, q.z);
    }
  }
}
