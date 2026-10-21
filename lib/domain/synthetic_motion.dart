import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'orientation.dart';

/// Deterministic orientation as a function of time, for UI work until real
/// IMU fusion exists. [yawDriftRadPerS] adds a steady yaw drift so
/// "reset orientation" has something to remove.
class SyntheticMotion {
  const SyntheticMotion({this.yawDriftRadPerS = 0.05});

  final double yawDriftRadPerS;

  Quaternion at(Duration t) {
    final s = t.inMicroseconds / 1e6;
    final yaw = 0.9 * math.sin(0.4 * s) + yawDriftRadPerS * s;
    final pitch = 0.5 * math.sin(0.7 * s + 1.0);
    final roll = 0.6 * math.sin(1.1 * s);
    return quaternionFromEuler(yaw, pitch, roll);
  }
}
