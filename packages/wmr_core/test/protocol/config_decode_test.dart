import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/protocol/config_decode.dart';

/// A synthetic key. NOT Monado's table.
Uint8List _key() =>
    Uint8List.fromList([for (var i = 0; i < 1024; i++) (i * 31 + 7) & 0xff]);

/// Inverse of [deobfuscateConfig]: 2 prefix bytes, then text XOR key.
Uint8List _obfuscate(String text, Uint8List key, {int pad = 0}) {
  final bytes = [...utf8.encode(text), ...List.filled(pad, 0)];
  return Uint8List.fromList([
    0xab,
    0xcd,
    for (var i = 0; i < bytes.length; i++) bytes[i] ^ key[i % 1024],
  ]);
}

Map<String, Object?> _sensor(String type, {double base = 0}) => {
  'SensorType': type,
  'Rt': {
    'Rotation': [1, 0, 0, 0, 1, 0, 0, 0, 1],
    'Translation': [0.01, 0.02, 0.03],
  },
  'MixingMatrixTemperatureModel': [
    for (var i = 0; i < 36; i++) i % 4 == 0 ? 1.0 + i / 4 + base : 99.0,
  ],
  'BiasTemperatureModel': [
    for (var i = 0; i < 12; i++) i % 4 == 0 ? 0.1 * (i / 4 + 1) : 99.0,
  ],
  'BiasUncertainty': [0.1, 0.2, 0.3],
  'Noise': [1, 2, 3, 4, 5, 6],
};

String _doc() => jsonEncode({
  'CalibrationInformation': {
    'InertialSensors': [
      _sensor('CALIBRATION_InertialSensorType_Gyro'),
      _sensor('CALIBRATION_InertialSensorType_Accelerometer', base: 10),
    ],
  },
});

void main() {
  test('de-obfuscation skips 2 bytes, XORs with key[i % 1024], drops NULs', () {
    final key = _key();
    final text = '{"a":"${'x' * 1500}"}'; // longer than the key: wraps
    expect(deobfuscateConfig(_obfuscate(text, key, pad: 5), key), text);
  });

  test('rejects a wrong-size key, a too-short block and non-text output', () {
    expect(
      () => deobfuscateConfig(Uint8List(10), Uint8List(1000)),
      throwsArgumentError,
    );
    expect(
      () => deobfuscateConfig(Uint8List(2), _key()),
      throwsFormatException,
    );
    // A wrong key turns ASCII into bytes that are not UTF-8.
    final wrong = Uint8List.fromList([for (var i = 0; i < 1024; i++) 0xff]);
    expect(
      () => deobfuscateConfig(_obfuscate(_doc(), _key()), wrong),
      throwsFormatException,
    );
  });

  test('parses sensors: first temperature coefficient only', () {
    final key = _key();
    final cal = parseControllerCalibration(
      deobfuscateConfig(_obfuscate(_doc(), key), key),
    );
    expect(cal.sensors, hasLength(2));
    final gyro = cal.sensor(InertialSensorType.gyro)!;
    expect(gyro.rotation, [1, 0, 0, 0, 1, 0, 0, 0, 1]);
    expect(gyro.translation, [0.01, 0.02, 0.03]);
    expect(gyro.mixMatrix, [for (var i = 0; i < 9; i++) 1.0 + i]);
    expect(gyro.bias, [
      closeTo(0.1, 1e-9),
      closeTo(0.2, 1e-9),
      closeTo(0.3, 1e-9),
    ]);
    expect(gyro.biasUncertainty, [0.1, 0.2, 0.3]);
    expect(gyro.noise, [1, 2, 3, 4, 5, 6]);
    final accel = cal.sensor(InertialSensorType.accelerometer)!;
    expect(accel.mixMatrix.first, 11.0);
    expect(cal.sensor(InertialSensorType.magnetometer), isNull);
  });

  test('malformed documents throw FormatException', () {
    expect(() => parseControllerCalibration('not json'), throwsFormatException);
    expect(() => parseControllerCalibration('{}'), throwsFormatException);
    expect(
      () => parseControllerCalibration(
        jsonEncode({
          'CalibrationInformation': {
            'InertialSensors': [
              {
                'SensorType': 'CALIBRATION_InertialSensorType_Gyro',
                'Rt': {
                  'Rotation': List.filled(9, 0),
                  'Translation': [0, 0, 0],
                },
                'MixingMatrixTemperatureModel': [1, 2],
                'BiasTemperatureModel': List.filled(12, 0),
              },
            ],
          },
        }),
      ),
      throwsFormatException,
    );
  });
}
