import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/controller_service.dart';

void main() {
  test(
    'onStreamValue sees each FF14 batch as received, before parsing',
    () async {
      final t = FakeTransport(devices: const [fakeBridgeDevice]);
      final seen = <({Uint8List value, int receivedAtUs, String id})>[];
      final service = ControllerService(
        t,
        fakeBridgeDeviceId,
        mode: StreamMode.batched,
        onStreamValue: (value, receivedAtUs, id) {
          seen.add((value: value, receivedAtUs: receivedAtUs, id: id));
        },
      );
      addTearDown(() async {
        await service.dispose();
        await t.dispose();
      });
      await service.start();

      final batch = encodeDecodedBatch([
        encodeDecodedRecord(
          const DecodedRecord(
            hand: 0,
            sequence: 5,
            rxTimeUs: 0,
            deviceTicks: 100,
            gyro: [0.0, 0.0, 0.0],
            accel: [0.0, 0.0, 0.0],
          ),
        ),
      ]);
      t.emit(fakeBridgeDeviceId, wmrBridgeBatchedCharUuid, batch);
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.value, batch);
      expect(seen.single.id, fakeBridgeDeviceId);
    },
  );
}
