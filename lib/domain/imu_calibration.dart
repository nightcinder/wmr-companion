/// Applies the FF13 inertial calibration to raw IMU samples.
///
/// This is a port of the per-sample order in Monado's WMR controller driver,
/// read at commit `aa635fa755a779f8aee717647c44aa7282e6ca45`:
///
/// - `src/xrt/drivers/wmr/wmr_controller_hp.c`,
///   `wmr_controller_hp_packet_parse` (the same code is in
///   `wmr_controller_og.c`): mix matrix, then add the bias, then rotate by
///   the precomputed pose.
/// - `src/xrt/drivers/wmr/wmr_config.c`,
///   `wmr_inertial_sensor_config_parse` (mix coefficients `model[4*i]` and
///   bias `model[0]`, `model[4]`, `model[8]`) and
///   `wmr_config_precompute_transforms` (`P_oxr_acc` / `P_oxr_gyr`).
///
/// The arithmetic is, for one sensor:
///
/// ```text
/// calibrated = R^T * (M * raw + bias)
/// ```
///
/// where `M` is `MixingMatrixTemperatureModel` (the constant coefficient of
/// each of the nine temperature models) and `R` is `Rt.Rotation` (row
/// major). Monado applies `M` with `math_matrix_3x3_transform_vec3`, adds the
/// bias with `math_vec3_accum`, then rotates with `math_quat_rotate_vec3` and
/// `P_oxr_*`. Those poses are `P_oxr_wmr * inv(P_*_ht0)`: the `inv(P_*_ht0)`
/// part is the `R^T` above. The `P_oxr_wmr` part (WMR Y down / Z forward ->
/// OpenXR Y up / Z back) is the app's frame conversion and stays in
/// `AxisMapping`, so it is not applied twice here.
///
/// Monado is BSL-1.0 (the WMR driver files are Copyright 2021 Jan Schmidt).
/// This is a re-implementation of the arithmetic, not a copy of Monado
/// source.
///
/// Pure Dart (no Flutter imports), so it is unit testable on its own. Nothing
/// here has been run on hardware.
library;

import '../protocol/config_decode.dart';

/// Calibration for the accelerometer and gyro of one controller.
class ImuCalibration {
  ImuCalibration.fromSensors({
    required InertialSensorCalibration accel,
    required InertialSensorCalibration gyro,
  }) : _accel = _SensorCalibration.from(accel),
       _gyro = _SensorCalibration.from(gyro);

  /// Builds from a decoded config, or returns null when the block has no
  /// accelerometer or no gyro entry (then there is nothing safe to apply).
  static ImuCalibration? fromController(ControllerCalibration calibration) {
    final accel = calibration.sensor(InertialSensorType.accelerometer);
    final gyro = calibration.sensor(InertialSensorType.gyro);
    if (accel == null || gyro == null) return null;
    return ImuCalibration.fromSensors(accel: accel, gyro: gyro);
  }

  final _SensorCalibration _accel;
  final _SensorCalibration _gyro;

  /// Raw accelerometer sample (sensor axes, m/s^2) -> calibrated sample.
  ///
  /// The result is in the controller body frame, not the view frame: the
  /// pipeline's `AxisMapping` still has to map it.
  List<double> calibrateAccel(List<double> raw) => _accel.apply(raw);

  /// Raw gyro sample (sensor axes, rad/s) -> calibrated sample.
  List<double> calibrateGyro(List<double> raw) => _gyro.apply(raw);
}

class _SensorCalibration {
  _SensorCalibration({
    required List<double> mix,
    required List<double> bias,
    required List<double> rotation,
  }) : _mix = List<double>.unmodifiable(_nine(mix, 'mixMatrix')),
       _bias = List<double>.unmodifiable(_three(bias, 'bias')),
       _rotationT = List<double>.unmodifiable(
         _transpose(_nine(rotation, 'rotation')),
       );

  factory _SensorCalibration.from(InertialSensorCalibration s) =>
      _SensorCalibration(mix: s.mixMatrix, bias: s.bias, rotation: s.rotation);

  final List<double> _mix;
  final List<double> _bias;

  /// Transpose of `Rt.Rotation`: Monado inverts the sensor pose (a rotation
  /// matrix, so the inverse is the transpose).
  final List<double> _rotationT;

  List<double> apply(List<double> raw) {
    if (raw.length < 3) {
      throw ArgumentError.value(raw, 'raw', 'expected 3 values');
    }
    final mixed = [
      _mix[0] * raw[0] + _mix[1] * raw[1] + _mix[2] * raw[2] + _bias[0],
      _mix[3] * raw[0] + _mix[4] * raw[1] + _mix[5] * raw[2] + _bias[1],
      _mix[6] * raw[0] + _mix[7] * raw[1] + _mix[8] * raw[2] + _bias[2],
    ];
    return [
      _rotationT[0] * mixed[0] +
          _rotationT[1] * mixed[1] +
          _rotationT[2] * mixed[2],
      _rotationT[3] * mixed[0] +
          _rotationT[4] * mixed[1] +
          _rotationT[5] * mixed[2],
      _rotationT[6] * mixed[0] +
          _rotationT[7] * mixed[1] +
          _rotationT[8] * mixed[2],
    ];
  }
}

List<double> _three(List<double> v, String name) {
  if (v.length < 3) throw ArgumentError.value(v, name, 'expected 3 values');
  return v.sublist(0, 3);
}

List<double> _nine(List<double> v, String name) {
  if (v.length < 9) throw ArgumentError.value(v, name, 'expected 9 values');
  return v.sublist(0, 9);
}

List<double> _transpose(List<double> m) => [
  m[0],
  m[3],
  m[6],
  m[1],
  m[4],
  m[7],
  m[2],
  m[5],
  m[8],
];
