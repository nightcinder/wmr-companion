# Changelog

## 0.2.2

- Version aligned with the v0.2.2 release; no breaking public API change.

## 0.2.1

- Version aligned with the v0.2.1 release; no breaking public API change.

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Initial release of pure-Dart 6-axis Madgwick and Mahony orientation filters.
- Implements `OrientationFilter` interface with Quaternion and Vector3 math primitives.
- Gravity-based tilt initialization on the first accelerometer sample.
- Sample validation skipping non-finite values and invalid `dt`.
- Yaw reset (`resetYaw`) and configurable filter parameters (`beta`, `Kp`, `Ki`).
