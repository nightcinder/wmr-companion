import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/fake_transport.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/protocol/config_block.dart';
import 'package:wmr_companion/services/config_client.dart';
import 'package:wmr_companion/services/config_key_store.dart';
import 'package:wmr_companion/services/config_report.dart';

/// A synthetic key. NOT Monado's table.
final _key = Uint8List.fromList([
  for (var i = 0; i < 1024; i++) (i * 31 + 7) & 0xff,
]);

Uint8List _block(String text) {
  final b = utf8.encode(text);
  return Uint8List.fromList([
    1,
    2,
    for (var i = 0; i < b.length; i++) b[i] ^ _key[i % 1024],
  ]);
}

final _sensor = {
  'SensorType': 'CALIBRATION_InertialSensorType_Gyro',
  'Rt': {
    'Rotation': [1, 0, 0, 0, 1, 0, 0, 0, 1],
    'Translation': [0.01, 0.02, 0.03],
  },
  'MixingMatrixTemperatureModel': [
    for (var i = 0; i < 36; i++) i % 4 == 0 ? 1.0 : 0.0,
  ],
  'BiasTemperatureModel': [for (var i = 0; i < 12; i++) i % 4 == 0 ? 0.5 : 0.0],
};

void main() {
  late FakeTransport transport;

  Future<ConfigClient> client(
    Uint8List? blob, {
    List<ConfigState>? states,
  }) async {
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    FakeWmrBridge(transport, configBlobs: [blob, null], configStates: states);
    await transport.connect(fakeBridgeDevice.id);
    return ConfigClient(
      transport,
      fakeBridgeDevice.id,
      readyTimeout: const Duration(milliseconds: 100),
      pollInterval: const Duration(milliseconds: 10),
    );
  }

  tearDown(() => transport.dispose());

  test('decodes a synthetic block with a synthetic key', () async {
    final text = jsonEncode({
      'CalibrationInformation': {
        'InertialSensors': [_sensor],
      },
    });
    final lines = (await readConfigReport(
      await client(_block(text)),
      0,
      keyLoader: () async => ConfigKeyResult.ok(_key),
    )).lines;
    expect(lines.first, contains('CRC-32'));
    expect(lines, contains('CALIBRATION_InertialSensorType_Gyro'));
    expect(lines.any((l) => l.contains('bias   0.5000, 0.5000')), isTrue);
  });

  test('a missing key still reports the read and says what to do', () async {
    final lines = (await readConfigReport(
      await client(Uint8List.fromList([1, 2, 3, 4])),
      0,
      keyLoader: () async =>
          const ConfigKeyResult.problem(ConfigKeyStatus.missing),
    )).lines;
    expect(lines.first, contains('Read 4 bytes'));
    expect(lines.last, contains('fetch_wmr_config_key'));
  });

  test('a wrong key is a decode failure, not a throw', () async {
    final lines = (await readConfigReport(
      await client(Uint8List.fromList(List.filled(40, 0xff))),
      0,
      keyLoader: () async => ConfigKeyResult.ok(_key),
    )).lines;
    expect(lines.last, startsWith('Decode failed'));
  });

  test('a bridge failure is reported', () async {
    final lines = (await readConfigReport(
      await client(null, states: [ConfigState.failed, ConfigState.failed]),
      0,
    )).lines;
    expect(lines.first, contains('bridgeFailed'));
  });
}
