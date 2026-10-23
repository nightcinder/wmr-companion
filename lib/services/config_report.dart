import 'package:wmr_core/protocol/config_decode.dart';
import 'package:wmr_core/services/config_client.dart';

import 'config_key_store.dart';

String _v(List<double> v) => v.map((x) => x.toStringAsFixed(4)).join(', ');

/// The outcome of a "Read config": the lines shown on the debug screen and,
/// when the block was read and decoded, the parsed calibration.
class ConfigReport {
  const ConfigReport(this.lines, {this.calibration});

  final List<String> lines;

  /// Parsed calibration, or null when the read or decode failed (or the key
  /// was missing). The lines say why.
  final ControllerCalibration? calibration;
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
