/// Decoding of a controller config block read over FF13.
///
/// The block is the controller's block 0x02 exactly as the controller sent it:
/// two leading bytes, then XOR-obfuscated JSON text. The XOR key is Monado's
/// fixed 1024-byte table (`wmr_config_key.h`, Copyright 2021 Jan Schmidt,
/// BSL-1.0), which this repository does not contain; the caller supplies it.
/// The JSON field names follow WMR_Bridge docs/DECODING.md ("Calibration:
/// design"), taken from Monado. Nothing here has been run on a real block:
/// tests use a synthetic key and a synthetic JSON document.
library;

import 'dart:convert';
import 'dart:typed_data';

const int wmrConfigKeySize = 1024;

/// Bytes to skip at the start of the block before de-obfuscating.
const int wmrConfigSkip = 2;

/// Drops the first two bytes and XORs the rest with `key[i % 1024]`, then
/// returns the text. Trailing NUL padding is removed.
String deobfuscateConfig(Uint8List blob, Uint8List key) {
  if (key.length != wmrConfigKeySize) {
    throw ArgumentError.value(
      key.length,
      'key',
      'must be $wmrConfigKeySize bytes',
    );
  }
  if (blob.length <= wmrConfigSkip) {
    throw const FormatException('config block shorter than its 2-byte prefix');
  }
  final n = blob.length - wmrConfigSkip;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = blob[wmrConfigSkip + i] ^ key[i % wmrConfigKeySize];
  }
  var end = n;
  while (end > 0 && out[end - 1] == 0) {
    end--;
  }
  try {
    return utf8.decode(Uint8List.sublistView(out, 0, end));
  } on FormatException {
    throw const FormatException(
      'de-obfuscated config is not UTF-8 text (wrong key, or a block that is '
      'not the config)',
    );
  }
}

/// Which sensor an [InertialSensorCalibration] describes.
enum InertialSensorType { gyro, accelerometer, magnetometer, unknown }

InertialSensorType _sensorType(String name) {
  if (name.endsWith('_Gyro')) return InertialSensorType.gyro;
  if (name.endsWith('_Accelerometer')) return InertialSensorType.accelerometer;
  if (name.endsWith('_Magnetometer')) return InertialSensorType.magnetometer;
  return InertialSensorType.unknown;
}

/// One entry of `CalibrationInformation.InertialSensors[]`.
class InertialSensorCalibration {
  const InertialSensorCalibration({
    required this.type,
    required this.typeName,
    required this.rotation,
    required this.translation,
    required this.mixMatrix,
    required this.bias,
    required this.biasUncertainty,
    required this.noise,
  });

  final InertialSensorType type;

  /// The `SensorType` string as found.
  final String typeName;

  /// `Rt.Rotation`: 9 floats, row-major 3x3 (the sensor's pose).
  final List<double> rotation;

  /// `Rt.Translation`: 3 floats.
  final List<double> translation;

  /// 3x3 row-major mixing matrix: the first coefficient of each of the 9
  /// elements of `MixingMatrixTemperatureModel` (`model[4*i]`, as Monado
  /// does; the temperature terms are ignored).
  final List<double> mixMatrix;

  /// Bias offsets: `(model[0], model[4], model[8])` of
  /// `BiasTemperatureModel`. To be **added** after the mix matrix.
  final List<double> bias;
  final List<double> biasUncertainty;
  final List<double> noise;
}

class ControllerCalibration {
  const ControllerCalibration(this.sensors);

  final List<InertialSensorCalibration> sensors;

  InertialSensorCalibration? sensor(InertialSensorType type) {
    for (final s in sensors) {
      if (s.type == type) return s;
    }
    return null;
  }
}

List<double> _floats(Object? v, int minLength, String field) {
  if (v is! List || v.length < minLength) {
    throw FormatException('$field: expected a list of at least $minLength');
  }
  return [
    for (final e in v)
      if (e is num)
        e.toDouble()
      else
        throw FormatException('$field: non-numeric entry'),
  ];
}

/// Parses the de-obfuscated JSON. Throws [FormatException] for a document
/// that does not have the expected shape; fields that Monado treats as
/// optional here (uncertainty, noise) default to empty.
ControllerCalibration parseControllerCalibration(String json) {
  final Object? root;
  try {
    root = jsonDecode(json);
  } on FormatException catch (e) {
    throw FormatException('config JSON: ${e.message}');
  }
  final info = root is Map ? root['CalibrationInformation'] : null;
  final sensors = info is Map ? info['InertialSensors'] : null;
  if (sensors is! List) {
    throw const FormatException(
      'config JSON has no CalibrationInformation.InertialSensors list',
    );
  }
  final out = <InertialSensorCalibration>[];
  for (final s in sensors) {
    if (s is! Map) continue;
    final name = s['SensorType'];
    if (name is! String) {
      throw const FormatException('inertial sensor without SensorType');
    }
    final rt = s['Rt'];
    if (rt is! Map) throw FormatException('$name: missing Rt');
    final mixModel = _floats(
      s['MixingMatrixTemperatureModel'],
      36,
      '$name MixingMatrixTemperatureModel',
    );
    final biasModel = _floats(
      s['BiasTemperatureModel'],
      12,
      '$name BiasTemperatureModel',
    );
    out.add(
      InertialSensorCalibration(
        type: _sensorType(name),
        typeName: name,
        rotation: _floats(rt['Rotation'], 9, '$name Rt.Rotation').sublist(0, 9),
        translation: _floats(
          rt['Translation'],
          3,
          '$name Rt.Translation',
        ).sublist(0, 3),
        mixMatrix: [for (var i = 0; i < 9; i++) mixModel[4 * i]],
        bias: [biasModel[0], biasModel[4], biasModel[8]],
        biasUncertainty: s['BiasUncertainty'] == null
            ? const []
            : _floats(s['BiasUncertainty'], 0, '$name BiasUncertainty'),
        noise: s['Noise'] == null
            ? const []
            : _floats(s['Noise'], 0, '$name Noise'),
      ),
    );
  }
  return ControllerCalibration(out);
}
