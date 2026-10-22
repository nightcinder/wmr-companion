import '../protocol/config_decode.dart';
import 'config_client.dart';
import 'config_key_store.dart';

String _v(List<double> v) => v.map((x) => x.toStringAsFixed(4)).join(', ');

/// Reads [hand]'s config block and turns the outcome into lines of text for
/// the debug screen. Never throws. Nothing here has been run on a real block.
Future<List<String>> readConfigReport(
  ConfigClient client,
  int hand, {
  Future<ConfigKeyResult> Function()? keyLoader,
}) async {
  final r = await client.read(hand);
  final blob = r.blob;
  if (blob == null) {
    return [
      'Read failed: ${r.failure!.name}'
          '${r.state != null ? ' (state ${r.state!.name})' : ''}',
      if (r.detail != null) r.detail!,
      if (client.lastError != null) '${client.lastError}',
    ];
  }
  final lines = [
    'Read ${blob.length} bytes, CRC-32 ${r.crc!.toRadixString(16)} OK',
  ];
  final key = await (keyLoader ?? loadConfigKey)();
  if (key.key == null) return [...lines, key.message];
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
  } on FormatException catch (e) {
    lines.add('Decode failed: ${e.message}');
  }
  return lines;
}
