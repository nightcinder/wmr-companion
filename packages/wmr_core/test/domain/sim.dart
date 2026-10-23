import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_core/domain/orientation.dart';
import 'package:wmr_core/protocol/decoded_record.dart';

/// 1 g as the controller reports it (about 10.0, not 9.81).
const double gravity = 10.0;

/// Ticks per report at the controller's nominal ~170 Hz.
const int nominalPeriodTicks = 58800;

/// Builds a record from a tick count; `rx_time_us` follows the ticks (100 ns
/// each) from [rxOriginUs].
DecodedRecord record({
  required int ticks,
  int hand = 0,
  int sequence = 0,
  List<double> gyro = const [0, 0, 0],
  List<double> accel = const [gravity, 0, 0],
  int rxOriginUs = 1000000,
  int? rxTimeUs,
  List<int> stick = const [0, 0],
  int buttons = 0,
  int flags = 0,
}) => DecodedRecord(
  stick: stick,
  buttons: buttons,
  flags: flags,
  hand: hand,
  sequence: sequence,
  rxTimeUs: rxTimeUs ?? rxOriginUs + ticks * wmrTickNanoseconds ~/ 1000,
  deviceTicks: ticks & 0xffffffff,
  gyro: gyro,
  accel: accel,
);

/// Sensor-frame samples for a rigid body at rest for [stillSeconds] and then
/// rotating at [rate] rad/s about sensor axis [axis] for [turnSeconds].
///
/// At rest the sensor X axis points up (the default mapping puts view Y,
/// up, on sensor +X), so accel reads (g, 0, 0). During the turn the accel is
/// what a body rotated by the angle so far would read: the fixed world "up"
/// expressed in the body frame, i.e. rotated by the opposite angle.
Iterable<DecodedRecord> sensorTurn({
  required int axis,
  required double rate,
  double stillSeconds = 1.2,
  double turnSeconds = 1.0,
  int periodTicks = nominalPeriodTicks,
  int startTicks = 1000,
  int hand = 0,
  int flags = 0,
}) sync* {
  final n = ((stillSeconds + turnSeconds) / (periodTicks * wmrTickSeconds))
      .round();
  final axisVec = vm.Vector3.zero()..[axis] = 1;
  var ticks = startTicks;
  for (var i = 0; i < n; i++) {
    final t = i * periodTicks * wmrTickSeconds;
    final turning = t >= stillSeconds;
    final angle = turning ? rate * (t - stillSeconds) : 0.0;
    // A fixed world "up" seen from a body turned by +angle is turned by
    // -angle (active rotation via rotateVector, not Quaternion.rotated).
    final accel = rotateVector(
      vm.Quaternion.axisAngle(axisVec, -angle),
      vm.Vector3(gravity, 0, 0),
    );
    yield record(
      ticks: ticks,
      hand: hand,
      sequence: i + 1,
      flags: flags,
      gyro: [for (var k = 0; k < 3; k++) k == axis && turning ? rate : 0.0],
      accel: [accel.x, accel.y, accel.z],
    );
    ticks += periodTicks;
  }
}

double degrees(double rad) => rad * 180 / math.pi;
