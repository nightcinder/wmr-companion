/// Nintendo Switch Joy-Con/Pro factory calibration carried over FF13.
///
/// The bridge reads two SPI flash regions from a Switch controller and packs
/// them into the hand's FF13 config blob:
///
/// - `0x6020`, 24 bytes: the 6-axis factory calibration, 12 x int16 LE.
/// - `0x603D`, 9 bytes: the left stick factory calibration.
/// - `0x6046`, 9 bytes: the right stick factory calibration.
///
/// Blob layout version 1 (44 bytes):
///
/// | Offset | Size | Meaning |
/// | --- | --- | --- |
/// | 0 | 1 | version, `1` |
/// | 1 | 1 | device type: `1` Joy-Con (L), `2` Joy-Con (R), `3` Pro |
/// | 2 | 24 | 6-axis calibration, in report order (see below) |
/// | 26 | 9 | left stick calibration |
/// | 35 | 9 | right stick calibration |
///
/// The 6-axis block is `accel origin X,Y,Z`, `accel sensitivity X,Y,Z`,
/// `gyro origin X,Y,Z`, `gyro sensitivity X,Y,Z`. The factory formulas are the
/// ones in Nintendo_Switch_Reverse_Engineering (`imu_sensor_notes.md`,
/// `spi_flash_notes.md`):
///
/// ```text
/// accel_g   = raw * 4.0 / (accel_sensitivity - accel_origin)
/// gyro_dps  = (raw - gyro_origin) * 936.0 / (gyro_sensitivity - gyro_origin)
/// ```
///
/// [SwitchCalibration.imuCalibration] rewrites those into the
/// `ImuCalibration` form (`calibrated = M * raw + bias`) using the nominal
/// scales a Switch decoder uses before factory calibration: `4/16384` G per
/// count and `0.06103` dps per count. FF12/FF14 Switch records are therefore
/// expected in those nominal units, rad/s and m/s^2 like every other model.
///
/// The stick blocks are the 9-byte factory layout: six 12-bit values, low
/// nibble first. The left block (`0x603D`) stores max-above-centre X/Y,
/// centre X/Y, min-below-centre X/Y; the right block (`0x6046`) stores centre
/// X/Y, min-below-centre X/Y, max-above-centre X/Y.
///
/// Nothing here has been run on a Switch controller; the layout and the math
/// follow the public reverse-engineering notes, not a capture from this
/// bridge. The FF13 packing is documented in this repository's
/// docs/PROTOCOL.md, "Switch calibration and burst timing"; the bridge driver
/// is WMR_Bridge ONY-946.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/imu_calibration.dart';
import 'config_decode.dart';

const int switchConfigVersion = 1;
const int switchConfigSize = 44;

/// Nominal scales of a decoded Switch sample, before factory calibration.
const double switchNominalAccelGPerCount = 4.0 / 16384.0;
const double switchNominalGyroDpsPerCount = 0.06103;
const double switchGravity = 9.80665;
const double switchDegreesToRadians = math.pi / 180.0;

enum SwitchDeviceType {
  joyConLeft(1),
  joyConRight(2),
  proController(3);

  const SwitchDeviceType(this.code);

  final int code;

  static SwitchDeviceType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// One stick's factory calibration: a 12-bit centre, travel above and below
/// it, per axis. Raw axis values are unsigned 12-bit (`0..4095`).
class SwitchStickCalibration {
  const SwitchStickCalibration({
    required this.aboveX,
    required this.aboveY,
    required this.centerX,
    required this.centerY,
    required this.belowX,
    required this.belowY,
  });

  /// Travel from the centre to the maximum, per axis.
  final int aboveX;
  final int aboveY;
  final int centerX;
  final int centerY;

  /// Travel from the centre to the minimum, per axis.
  final int belowX;
  final int belowY;

  int get maxX => centerX + aboveX;
  int get maxY => centerY + aboveY;
  int get minX => centerX - belowX;
  int get minY => centerY - belowY;

  /// [raw] (0..4095) as -1..1 around the centre, with each half rescaled to
  /// its own end stop. A degenerate axis (no travel) reads 0.
  List<double> normalize(int rawX, int rawY) => [
    _axis(rawX, centerX, minX, maxX),
    _axis(rawY, centerY, minY, maxY),
  ];

  static double _axis(int raw, int centre, int min, int max) {
    final d = raw - centre;
    final span = d >= 0 ? max - centre : centre - min;
    if (span <= 0) return 0;
    return (d / span).clamp(-1.0, 1.0).toDouble();
  }

  /// Parses one 9-byte factory block from SPI `0x603D` (left) or `0x6046`
  /// (right). Both store six 12-bit values, low nibble first; the left block
  /// is above/centre/below X then Y, the right block is centre/below/above X
  /// then Y.
  static SwitchStickCalibration parse(
    Uint8List bytes,
    int offset, {
    bool rightStick = false,
  }) {
    final b = offset;
    int low(int i) => bytes[b + i] & 0x0f;
    int high(int i) => (bytes[b + i] >> 4) & 0x0f;
    // One X/Y pair from three bytes.
    int x(int i) => bytes[b + i] | (low(i + 1) << 8);
    int y(int i) => high(i + 1) | (bytes[b + i + 2] << 4);
    final first = (x: x(0), y: y(0));
    final second = (x: x(3), y: y(3));
    final third = (x: x(6), y: y(6));
    return SwitchStickCalibration(
      aboveX: (rightStick ? third : first).x,
      aboveY: (rightStick ? third : first).y,
      centerX: (rightStick ? first : second).x,
      centerY: (rightStick ? first : second).y,
      belowX: (rightStick ? second : third).x,
      belowY: (rightStick ? second : third).y,
    );
  }
}

/// The 24-byte 6-axis factory calibration from SPI `0x6020`.
class SwitchSixAxisCalibration {
  const SwitchSixAxisCalibration({
    required this.accelOrigin,
    required this.accelSensitivity,
    required this.gyroOrigin,
    required this.gyroSensitivity,
  });

  final List<int> accelOrigin;
  final List<int> accelSensitivity;
  final List<int> gyroOrigin;
  final List<int> gyroSensitivity;

  static SwitchSixAxisCalibration parse(Uint8List bytes, int offset) {
    List<int> words(int at) => [
      for (var i = 0; i < 3; i++)
        ByteData.sublistView(bytes).getInt16(at + 2 * i, Endian.little),
    ];
    return SwitchSixAxisCalibration(
      accelOrigin: words(offset),
      accelSensitivity: words(offset + 6),
      gyroOrigin: words(offset + 12),
      gyroSensitivity: words(offset + 18),
    );
  }

  /// `ImuCalibration` for the decoded sample units, or null when a factory
  /// denominator is zero (a block that cannot be applied; the caller keeps
  /// the uncalibrated values).
  ImuCalibration? toImuCalibration() {
    final accel = _accelSensor();
    final gyro = _gyroSensor();
    if (accel == null || gyro == null) return null;
    return ImuCalibration.fromSensors(accel: accel, gyro: gyro);
  }

  InertialSensorCalibration? _accelSensor() {
    final scale = <double>[];
    for (var i = 0; i < 3; i++) {
      final den = accelSensitivity[i] - accelOrigin[i];
      if (den == 0) return null;
      scale.add(16384.0 / den);
    }
    return InertialSensorCalibration(
      type: InertialSensorType.accelerometer,
      typeName: 'Switch_Accelerometer',
      rotation: _identity,
      translation: const [0, 0, 0],
      mixMatrix: [
        scale[0], 0, 0, //
        0, scale[1], 0, //
        0, 0, scale[2],
      ],
      bias: const [0, 0, 0],
      biasUncertainty: const [],
      noise: const [],
    );
  }

  InertialSensorCalibration? _gyroSensor() {
    final scale = <double>[];
    final bias = <double>[];
    for (var i = 0; i < 3; i++) {
      final den = gyroSensitivity[i] - gyroOrigin[i];
      if (den == 0) return null;
      // Factory radians per raw count; the nominal count is what the decoded
      // record already multiplies the raw value by.
      final factoryRad = 936.0 * switchDegreesToRadians / den;
      scale.add(
        factoryRad / (switchNominalGyroDpsPerCount * switchDegreesToRadians),
      );
      bias.add(-gyroOrigin[i] * factoryRad);
    }
    return InertialSensorCalibration(
      type: InertialSensorType.gyro,
      typeName: 'Switch_Gyro',
      rotation: _identity,
      translation: const [0, 0, 0],
      mixMatrix: [
        scale[0], 0, 0, //
        0, scale[1], 0, //
        0, 0, scale[2],
      ],
      bias: bias,
      biasUncertainty: const [],
      noise: const [],
    );
  }

  static const List<double> _identity = [1, 0, 0, 0, 1, 0, 0, 0, 1];
}

/// A parsed Switch FF13 config blob.
class SwitchCalibration {
  const SwitchCalibration({
    required this.deviceType,
    required this.imu,
    this.leftStick,
    this.rightStick,
  });

  final SwitchDeviceType deviceType;
  final SwitchSixAxisCalibration imu;
  final SwitchStickCalibration? leftStick;
  final SwitchStickCalibration? rightStick;

  /// The stick that belongs to [hand] (0 LEFT, 1 RIGHT), or null.
  SwitchStickCalibration? stickForHand(int hand) =>
      hand == 0 ? leftStick : rightStick;

  /// Calibration for decoded FF12/FF14 Switch samples, or null when the
  /// factory block cannot be applied.
  ImuCalibration? get imuCalibration => imu.toImuCalibration();

  /// Parses [blob] (the FF13 hand block), or returns null when it is not a
  /// version 1 Switch calibration of the expected length and device type.
  static SwitchCalibration? parse(Uint8List blob) {
    if (blob.length != switchConfigSize) return null;
    if (blob[0] != switchConfigVersion) return null;
    final type = SwitchDeviceType.fromCode(blob[1]);
    if (type == null) return null;
    return SwitchCalibration(
      deviceType: type,
      imu: SwitchSixAxisCalibration.parse(blob, 2),
      leftStick: SwitchStickCalibration.parse(blob, 26),
      rightStick: SwitchStickCalibration.parse(blob, 35, rightStick: true),
    );
  }
}
