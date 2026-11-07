import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/domain/imu_calibration.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/switch_calibration.dart';

Uint8List blob({
  int version = 1,
  int deviceType = 1,
  List<int> accelOrigin = const [-123, 45, 1000],
  List<int> accelSensitivity = const [16384, 16000, 17000],
  List<int> gyroOrigin = const [10, -20, 30],
  List<int> gyroSensitivity = const [13371, 13000, 14000],
  List<int> leftStick = const [44, 161, 15, 0, 40, 128, 94, 1, 25],
  List<int> rightStick = const [0, 0, 0, 0, 0, 0, 0, 0, 0],
}) {
  final out = Uint8List(switchConfigSize);
  out[0] = version;
  out[1] = deviceType;
  final d = ByteData.sublistView(out);
  for (var i = 0; i < 3; i++) {
    d
      ..setInt16(2 + 2 * i, accelOrigin[i], Endian.little)
      ..setInt16(8 + 2 * i, accelSensitivity[i], Endian.little)
      ..setInt16(14 + 2 * i, gyroOrigin[i], Endian.little)
      ..setInt16(20 + 2 * i, gyroSensitivity[i], Endian.little);
  }
  out.setRange(26, 35, leftStick);
  out.setRange(35, 44, rightStick);
  return out;
}

void main() {
  group('SwitchCalibration.parse', () {
    test('decodes the device type and the six-axis block', () {
      final c = SwitchCalibration.parse(blob(deviceType: 2))!;
      expect(c.deviceType, SwitchDeviceType.joyConRight);
      expect(c.imu.accelOrigin, [-123, 45, 1000]);
      expect(c.imu.accelSensitivity, [16384, 16000, 17000]);
      expect(c.imu.gyroOrigin, [10, -20, 30]);
      expect(c.imu.gyroSensitivity, [13371, 13000, 14000]);
    });

    test('rejects a wrong length, version or device type', () {
      expect(SwitchCalibration.parse(Uint8List(43)), isNull);
      expect(SwitchCalibration.parse(Uint8List(switchConfigSize + 1)), isNull);
      expect(SwitchCalibration.parse(blob(version: 2)), isNull);
      expect(SwitchCalibration.parse(blob(deviceType: 0)), isNull);
      expect(SwitchCalibration.parse(blob(deviceType: 4)), isNull);
    });

    test('recognises every Switch device type', () {
      expect(
        SwitchCalibration.parse(blob(deviceType: 1))!.deviceType,
        SwitchDeviceType.joyConLeft,
      );
      expect(
        SwitchCalibration.parse(blob(deviceType: 3))!.deviceType,
        SwitchDeviceType.proController,
      );
    });
  });

  group('factory stick calibration', () {
    test('unpacks the six 12-bit values', () {
      final c = SwitchCalibration.parse(blob())!;
      final s = c.leftStick!;
      expect(s.aboveX, 300);
      expect(s.aboveY, 250);
      expect(s.centerX, 2048);
      expect(s.centerY, 2050);
      expect(s.belowX, 350);
      expect(s.belowY, 400);
      expect(s.maxX, 2348);
      expect(s.minY, 1650);
    });

    test('normalizes each half to its own end stop', () {
      final s = SwitchCalibration.parse(blob())!.leftStick!;
      expect(s.normalize(2048, 2050), [0.0, 0.0]);
      expect(s.normalize(2348, 1650), [1.0, -1.0]);
      expect(s.normalize(1698, 2300), [-1.0, 1.0]);
    });

    test('a degenerate axis reads zero instead of dividing by zero', () {
      final zero = SwitchCalibration.parse(
        blob(leftStick: const [0, 0, 0, 0, 0, 0, 0, 0, 0]),
      )!;
      expect(zero.leftStick!.normalize(4095, 4095), [0.0, 0.0]);
    });

    test('the hand picks the matching stick block', () {
      final c = SwitchCalibration.parse(blob())!;
      expect(c.stickForHand(0), same(c.leftStick));
      expect(c.stickForHand(1), same(c.rightStick));
    });
  });

  group('factory six-axis calibration', () {
    test('maps decoded samples with the factory scale and gyro origin', () {
      final cal = SwitchCalibration.parse(blob())!.imuCalibration!;
      final gyro = cal.calibrateGyro([1.0, 2.0, -3.0]);
      final accel = cal.calibrateAccel([4.0, -5.0, 6.0]);
      expect(gyro[0], closeTo(1.1356453, 1e-6));
      expect(gyro[1], closeTo(2.380965, 1e-6));
      expect(gyro[2], closeTo(-3.328579, 1e-6));
      expect(accel[0], closeTo(3.9701945, 1e-6));
      expect(accel[1], closeTo(-5.1344406, 1e-6));
      expect(accel[2], closeTo(6.144, 1e-9));
    });

    test('a zero factory denominator yields no calibration', () {
      final zeroAccel = SwitchCalibration.parse(
        blob(accelSensitivity: const [16384, 45, 17000]),
      )!;
      expect(zeroAccel.imuCalibration, isNull);
      final zeroGyro = SwitchCalibration.parse(
        blob(gyroSensitivity: const [10, 13000, 14000]),
      )!;
      expect(zeroGyro.imuCalibration, isNull);
    });

    test('the calibration is an ImuCalibration, not a second code path', () {
      expect(
        SwitchCalibration.parse(blob())!.imuCalibration,
        isA<ImuCalibration>(),
      );
    });

    test('applies to the fields of a decoded FF12/FF14 sample', () {
      final cal = SwitchCalibration.parse(blob())!.imuCalibration!;
      const sample = DecodedRecord(
        hand: 0,
        sequence: 4,
        rxTimeUs: 1000,
        deviceTicks: 5000,
        gyro: [1.0, 2.0, -3.0],
        accel: [4.0, -5.0, 6.0],
      );
      final gyro = cal.calibrateGyro(sample.gyro);
      final accel = cal.calibrateAccel(sample.accel);
      expect(gyro[0], closeTo(1.1356453, 1e-6));
      expect(gyro[1], closeTo(2.380965, 1e-6));
      expect(gyro[2], closeTo(-3.328579, 1e-6));
      expect(accel[0], closeTo(3.9701945, 1e-6));
      expect(accel[1], closeTo(-5.1344406, 1e-6));
      expect(accel[2], closeTo(6.144, 1e-9));
      expect(sample.gyro, [1.0, 2.0, -3.0]);
    });
  });
}
