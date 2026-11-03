import 'dart:math' as math;

import 'quaternion.dart';
import 'vector3.dart';

/// Gyro + accelerometer orientation filter (3DoF, no magnetometer).
///
/// Conventions:
/// - Body frame: right-handed, the (already calibrated and axis-mapped)
///   sensor frame.
/// - World frame: right-handed, +z up. Heading (yaw) has no absolute
///   reference and drifts.
/// - [orientation] rotates body vectors into the world frame.
/// - Gyro: angular rate in rad/s about the body axes (right-hand rule).
/// - Accel: specific force in m/s^2 as an accelerometer reports it. At rest
///   and level it reads about +10 on the body axis pointing up.
/// - dt: seconds since the previous sample.
abstract class OrientationFilter {
  /// Feeds one sample. Never throws and never produces a non-finite
  /// orientation: bad dt or non-finite input skips the sample (see
  /// [skippedUpdates]); a near-zero accel skips only the accel correction.
  ///
  /// The first sample with a usable accel only seeds the tilt (no
  /// integration), so its dt is ignored.
  void update({
    required Vector3 gyro,
    required Vector3 accel,
    required double dt,
  });

  /// Current unit quaternion (body to world).
  Quaternion get orientation;

  /// Number of samples rejected for invalid dt or non-finite input.
  int get skippedUpdates;

  /// Forgets the state and re-initializes tilt from the next usable accel
  /// sample, or sets [orientation] directly if given (it is normalized).
  /// Also clears [skippedUpdates].
  void reset({Quaternion? orientation});

  /// Zeroes heading (yaw) while keeping tilt (pitch and roll).
  void resetYaw();
}

/// Shared validation, initialization and yaw handling.
abstract class OrientationFilterBase implements OrientationFilter {
  /// Largest accepted dt in seconds; larger values are skipped as gaps.
  final double maxDt;

  /// Accel vectors shorter than this (m/s^2) are treated as unusable (free
  /// fall or a dead sensor) and skip the accel correction.
  final double minAccelNorm;

  double _w = 1, _x = 0, _y = 0, _z = 0;
  bool _initialized = false;
  int _skipped = 0;

  OrientationFilterBase({this.maxDt = 0.1, this.minAccelNorm = 0.1})
    : assert(maxDt > 0),
      assert(minAccelNorm > 0);

  @override
  Quaternion get orientation => Quaternion(_w, _x, _y, _z);

  @override
  int get skippedUpdates => _skipped;

  /// Whether the orientation has been seeded (first accel sample or [reset]).
  bool get isInitialized => _initialized;

  @override
  void reset({Quaternion? orientation}) {
    _skipped = 0;
    onReset();
    if (orientation != null && orientation.isFinite) {
      _set(orientation.normalized());
      _initialized = true;
    } else {
      _set(Quaternion.identity);
      _initialized = false;
    }
  }

  @override
  void resetYaw() {
    // Compute the heading from the quaternion components, not via toEuler(),
    // and detect gimbal lock explicitly: near pitch = +/-90 degrees the heading
    // is undefined and both terms below vanish. Extracting it there would turn
    // rounding noise into an arbitrary yaw, so leave the orientation alone.
    final q = orientation;
    final sinYaw = 2 * (q.w * q.z + q.x * q.y);
    final cosYaw = 1 - 2 * (q.y * q.y + q.z * q.z);
    if (sinYaw * sinYaw + cosYaw * cosYaw < 1e-12) return;
    final unyaw = Quaternion.fromAxisAngle(
      const Vector3(0, 0, 1),
      -math.atan2(sinYaw, cosYaw),
    );
    _set((unyaw * q).normalized());
  }

  @override
  void update({
    required Vector3 gyro,
    required Vector3 accel,
    required double dt,
  }) {
    if (!gyro.isFinite || !accel.isFinite) {
      _skipped++;
      return;
    }
    final accelUsable = accel.length >= minAccelNorm;

    if (!_initialized) {
      if (accelUsable) {
        _set(_tiltFromAccel(accel));
        _initialized = true;
      }
      return;
    }

    if (!dt.isFinite || dt <= 0 || dt > maxDt) {
      _skipped++;
      return;
    }

    step(gyro, accelUsable ? accel.normalized() : null, dt);

    final q = Quaternion(_w, _x, _y, _z);
    _set(q.isFinite ? q.normalized() : Quaternion.identity);
  }

  /// Subclass hook: advance the state (read via [w]/[x]/[y]/[z], write via
  /// [setState]) by one step. [accelUnit] is the normalized accel, or null
  /// when it must be ignored. The caller renormalizes.
  void step(Vector3 gyro, Vector3? accelUnit, double dt);

  /// Subclass hook: clear extra state (e.g. an integral term).
  void onReset() {}

  double get w => _w;
  double get x => _x;
  double get y => _y;
  double get z => _z;

  void setState(double w, double x, double y, double z) {
    _w = w;
    _x = x;
    _y = y;
    _z = z;
  }

  void _set(Quaternion q) => setState(q.w, q.x, q.y, q.z);

  /// Shortest-arc rotation taking the measured "up" (accel direction in the
  /// body frame) onto world +z; yaw comes out near 0.
  static Quaternion _tiltFromAccel(Vector3 accel) {
    final a = accel.normalized();
    if (a.z < -0.999999) return const Quaternion(0, 1, 0, 0); // upside down
    return Quaternion(1 + a.z, a.y, -a.x, 0).normalized();
  }
}

/// First-order quaternion integration of body rate [g] (rad/s) over [dt].
Quaternion integrateRate(
  double w,
  double x,
  double y,
  double z,
  Vector3 g,
  double dt,
) {
  final h = 0.5 * dt;
  return Quaternion(
    w + h * (-x * g.x - y * g.y - z * g.z),
    x + h * (w * g.x + y * g.z - z * g.y),
    y + h * (w * g.y - x * g.z + z * g.x),
    z + h * (w * g.z + x * g.y - y * g.x),
  );
}
