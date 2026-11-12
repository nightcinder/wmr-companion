# wmr_fusion

Pure Dart 3DoF orientation filters (Madgwick and Mahony, 6-axis) for gyro + accelerometer samples. No Flutter dependency, no external math dependency.

## Usage

```dart
import 'package:wmr_fusion/wmr_fusion.dart';

final OrientationFilter filter = MadgwickFilter(beta: 0.05);
// or: MahonyFilter(kp: 1.0, ki: 0.05);

// Per IMU sample:
filter.update(
  gyro: Vector3(gx, gy, gz),     // rad/s
  accel: Vector3(ax, ay, az),    // m/s^2, about 10.0 at rest
  dt: dtSeconds,                 // seconds since the previous sample
);

final q = filter.orientation;    // body -> world, unit quaternion
final e = q.toEuler();           // (yaw, pitch, roll) in radians

filter.resetYaw();               // zero heading, keep tilt
filter.reset();                  // re-seed tilt from the next accel sample
print(filter.skippedUpdates);    // samples rejected (bad dt, non-finite input)
```

## Units and frame

- Gyro: rad/s about the body axes, right-hand rule.
- Accel: m/s^2, specific force as an accelerometer reports it (reads about +10 on the body axis pointing up when at rest).
- dt: seconds.
- Body frame: right-handed sensor frame. World frame: right-handed, +z up.
- `orientation` rotates body vectors into the world frame: `q.rotate(vBody)` gives `vWorld`.
- Euler angles are intrinsic Z-Y-X (yaw about z, pitch about y, roll about x).

## Behavior

- The first usable accel sample seeds the tilt (yaw starts near 0); no integration happens on that sample, so its dt is ignored.
- `dt <= 0`, non-finite, or larger than `maxDt` (default 0.1 s) skips the whole sample and increments `skippedUpdates`. Non-finite gyro/accel is skipped and counted too.
- Accel shorter than `minAccelNorm` (default 0.1 m/s^2) skips only the accel correction; the gyro is still integrated.
- The quaternion is renormalized after every update.
- `reset(orientation: q)` sets the state directly (also clears `skippedUpdates` and Mahony's integral).

## Tuning

- Madgwick `beta` (default 0.05): higher means faster gravity correction, more sensitivity to linear acceleration.
- Mahony `kp` (default 1.0) and `ki` (default 0.05): `ki` estimates a constant gyro bias, readable as `gyroBiasEstimate` (rad/s), clamped to `maxBias`. Set `ki: 0` to disable.

## Not handled

- No magnetometer: yaw has no absolute reference and drifts. Use `resetYaw()` to re-zero it.
- No calibration: gyro bias (beyond Mahony's slow integral estimate), scale and sensor-axis mapping must be applied before calling `update`.
- Sustained linear acceleration (swinging the controller) corrupts the gravity reference and briefly bends tilt.
- No timestamp handling; the caller supplies dt.

## Tests

```
dart pub get
dart analyze
dart test
```
