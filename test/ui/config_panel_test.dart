import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/services/config_key_store.dart';
import 'package:wmr_companion/ui/debug/config_panel.dart';
import 'package:wmr_companion/ui/debug/stream_settings.dart';

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

Map<String, Object> _sensor(String type) => {
  'SensorType': type,
  'Rt': {
    'Rotation': [1, 0, 0, 0, 1, 0, 0, 0, 1],
    'Translation': [0, 0, 0],
  },
  'MixingMatrixTemperatureModel': [
    for (var i = 0; i < 36; i++) i % 4 == 0 ? 1.0 : 0.0,
  ],
  'BiasTemperatureModel': [for (var i = 0; i < 12; i++) 0.0],
};

void main() {
  testWidgets('FF13 switch stays off and disabled until a successful read', (
    tester,
  ) async {
    final text = jsonEncode({
      'CalibrationInformation': {
        'InertialSensors': [
          _sensor('CALIBRATION_InertialSensorType_Gyro'),
          _sensor('CALIBRATION_InertialSensorType_Accelerometer'),
        ],
      },
    });
    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    FakeWmrBridge(transport, configBlobs: [_block(text), null]);
    await transport.connect(fakeBridgeDeviceId);
    addTearDown(transport.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ConfigPanel(
              transport: transport,
              deviceId: fakeBridgeDeviceId,
              hand: 0,
              keyLoader: () async => ConfigKeyResult.ok(_key),
            ),
          ),
        ),
      ),
    );

    final sw = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(sw).onChanged, isNull);
    expect(container.read(ff13SettingsProvider).apply[0], isFalse);
    expect(find.textContaining('Read the config first'), findsOneWidget);

    await tester.tap(find.textContaining('Read config'));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(sw).onChanged, isNotNull);
    expect(container.read(ff13SettingsProvider).calibrations[0], isNotNull);
    expect(container.read(ff13SettingsProvider).apply[0], isFalse);

    await tester.tap(sw);
    await tester.pump();

    expect(container.read(ff13SettingsProvider).apply[0], isTrue);
    expect(find.textContaining('Active for LEFT'), findsOneWidget);
  });
}
