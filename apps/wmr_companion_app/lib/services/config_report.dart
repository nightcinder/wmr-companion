import 'package:wmr_core/domain/imu_calibration.dart';
import 'package:wmr_core/protocol/config_decode.dart';
import 'package:wmr_core/protocol/switch_calibration.dart';
import 'package:wmr_core/services/config_client.dart';

import 'config_key_store.dart';

String _v(List<double> v) => v.map((x) => x.toStringAsFixed(4)).join(', ');

String _i(List<int> v) => v.join(', ');

/// The outcome of a "Read config": the lines shown on the debug screen and,
/// when the block was read and decoded, the parsed calibration.
class ConfigReport {
  const ConfigReport(this.lines, {this.calibration, this.switchCalibration});

  final List<String> lines;

  /// Parsed WMR calibration, or null when the read or decode failed (or the
  /// key was missing). The lines say why.
  final ControllerCalibration? calibration;

  /// Parsed Switch factory calibration (FF17 model Switch, FF13 SPI block),
  /// or null for a WMR block or a failed read.
  final SwitchCalibration? switchCalibration;

  /// The calibration to apply, from either block kind, or null.
  ImuCalibration? get imuCalibration {
    final switchBlob = switchCalibration;
    if (switchBlob != null) return switchBlob.imuCalibration;
    final wmr = calibration;
    return wmr == null ? null : ImuCalibration.fromController(wmr);
  }
}

/// Reads [hand]'s config block and turns the outcome into lines of text for
/// the debug screen. Never throws. Nothing here has been run on a real block.
Future<ConfigReport> readConfigReport(
  ConfigClient client,
  int hand, {
  Future<ConfigKeyResult> Function()? keyLoader,
}) async {
  final r = await client.read(hand);
  final blob = r.blob;
  if (blob == null) {
    return ConfigReport([
      'Read failed: ${r.failure!.name}'
          '${r.state != null ? ' (state ${r.state!.name})' : ''}',
      if (r.detail != null) r.detail!,
      if (client.lastError != null) '${client.lastError}',
    ]);
  }
  final lines = [
    'Read ${blob.length} bytes, CRC-32 ${r.crc!.toRadixString(16)} OK',
  ];
  // A Switch hand's FF13 block is the self-describing 44-byte factory blob,
  // not the XOR-obfuscated WMR JSON: it needs no config key.
  final switchBlob = SwitchCalibration.parse(blob);
  if (switchBlob != null) {
    final imu = switchBlob.imu;
    lines
      ..add('Switch ${switchBlob.deviceType.name} factory calibration')
      ..add('  accel origin ${_i(imu.accelOrigin)}')
      ..add('  accel sens   ${_i(imu.accelSensitivity)}')
      ..add('  gyro origin  ${_i(imu.gyroOrigin)}')
      ..add('  gyro sens    ${_i(imu.gyroSensitivity)}');
    final stick = switchBlob.stickForHand(hand);
    if (stick != null) {
      lines
        ..add('  stick centre ${stick.centerX}, ${stick.centerY}')
        ..add(
          '  stick range  x ${stick.minX}..${stick.maxX}, '
          'y ${stick.minY}..${stick.maxY}',
        );
    }
    if (switchBlob.imuCalibration == null) {
      lines.add('  not applicable: a factory denominator is zero');
    }
    return ConfigReport(lines, switchCalibration: switchBlob);
  }
  final key = await (keyLoader ?? loadConfigKey)();
  if (key.key == null) return ConfigReport([...lines, key.message]);
  try {
    final cal = parseControllerCalibration(deobfuscateConfig(blob, key.key!));
    if (cal.sensors.isEmpty) lines.add('No inertial sensors in the config.');
    for (final s in cal.sensors) {
      lines
        ..add(s.typeName)
        ..add('  bias   ${_v(s.bias)}')
        ..add('  mix    ${_v(s.mixMatrix)}')
        ..add('  Rt.rot ${_v(s.rotation)}')
        ..add('  Rt.pos ${_v(s.translation)}');
    }
    return ConfigReport(lines, calibration: cal);
  } on FormatException catch (e) {
    return ConfigReport([...lines, 'Decode failed: ${e.message}']);
  }
}
