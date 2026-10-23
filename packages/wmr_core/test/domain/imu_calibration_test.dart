import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:wmr_core/domain/imu_calibration.dart';
import 'package:wmr_core/protocol/config_decode.dart';

const _identity = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];

InertialSensorCalibration sensor({
  required InertialSensorType type,
  List<double> rotation = _identity,
  List<double> mix = _identity,
  List<double> bias = const <double>[0, 0, 0],
}) => InertialSensorCalibration(
  type: type,
  typeName: type == InertialSensorType.gyro
      ? 'CALIBRATION_InertialSensorType_Gyro'
      : 'CALIBRATION_InertialSensorType_Accelerometer',
  rotation: rotation,
  translation: const [0, 0, 0],
  mixMatrix: mix,
  bias: bias,
  biasUncertainty: const [0, 0, 0],
  noise: const [0, 0, 0],
);

ImuCalibration calibration({
  List<double> rotation = _identity,
  List<double> mix = _identity,
  List<double> bias = const <double>[0, 0, 0],
}) => ImuCalibration.fromSensors(
  accel: sensor(
    type: InertialSensorType.accelerometer,
    rotation: rotation,
    mix: mix,
    bias: bias,
  ),
  gyro: sensor(
    type: InertialSensorType.gyro,
    rotation: rotation,
    mix: mix,
    bias: bias,
  ),
);

void main() {
  test('identity calibration returns the sample unchanged', () {
    final c = calibration();
    for (final raw in [
      const [0.0, 0.0, 0.0],
      const [1.0, -2.0, 3.5],
      const [10.0, 0.0, 0.0],
    ]) {
      expect(c.calibrateAccel(raw), raw);
      expect(c.calibrateGyro(raw), raw);
    }
  });

  test('mix, bias and inverse Rt in Monado order', () {
    // Hand-computed against Monado's per-sample order, read at
    // aa635fa755a779f8aee717647c44aa7282e6ca45:
    //   wmr_controller_hp_packet_parse:
    //     math_matrix_3x3_transform_vec3(&mix_matrix, &v, &v)
    //     math_vec3_accum(&bias_offsets, &v)
    //     math_quat_rotate_vec3(&P_oxr_acc.orientation, &v, &v)
    // `math_matrix_3x3_transform_vec3` multiplies by the row-major matrix
    // (its Eigen comma initializer fills rows), and P_oxr_* contains
    // inv(Rt) (wmr_config_precompute_transforms).
    //
    // raw = (1, 2, 3)
    // M * raw = (14, 32, 50)
    // + bias (0.5, -1, 2) = (14.5, 31, 52)
    // Rt = +90 deg about Z, so inv(Rt) = -90 deg about Z:
    //   (x, y, z) -> (y, -x, z)
    // result = (31, -14.5, 52)
    final c = calibration(
      rotation: const [0, -1, 0, 1, 0, 0, 0, 0, 1],
      mix: const [1, 2, 3, 4, 5, 6, 7, 8, 9],
      bias: const [0.5, -1, 2],
    );
    expect(c.calibrateAccel(const [1, 2, 3]), [31, -14.5, 52]);
    expect(c.calibrateGyro(const [1, 2, 3]), [31, -14.5, 52]);
  });

  test('a pure rotation keeps the magnitude (no scale is applied)', () {
    // The open accel-scale question (about 10 instead of 9.81, WMR_Bridge
    // #19) is not touched: the calibration has no scale factor, and an
    // orthonormal Rt preserves the norm. This test says what the port does,
    // not that 10 is right.
    final c = calibration(rotation: const [0, -1, 0, 1, 0, 0, 0, 0, 1]);
    final out = c.calibrateAccel(const [0, 10, 0]);
    expect(
      math.sqrt(out[0] * out[0] + out[1] * out[1] + out[2] * out[2]),
      closeTo(10, 1e-12),
    );
    expect(out, [10, 0, 0]);
  });

  test('fromController needs both accel and gyro', () {
    final accel = sensor(type: InertialSensorType.accelerometer);
    final gyro = sensor(type: InertialSensorType.gyro);
    final full = ImuCalibration.fromController(
      ControllerCalibration([accel, gyro]),
    );
    expect(full, isNotNull);
    expect(full!.calibrateAccel(const [1, 2, 3]), const [1, 2, 3]);

    expect(
      ImuCalibration.fromController(ControllerCalibration([accel])),
      isNull,
    );
    expect(
      ImuCalibration.fromController(ControllerCalibration([gyro])),
      isNull,
    );
  });

  test('a short sample is rejected', () {
    final c = calibration();
    expect(() => c.calibrateAccel(const [1, 2]), throwsArgumentError);
  });
}
