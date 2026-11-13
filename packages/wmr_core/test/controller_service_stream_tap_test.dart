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

  test(
    'onStreamValue sees each FF12 notification as received, before parsing',
    () async {
      final t = FakeTransport(devices: const [fakeBridgeDevice]);
      final seen = <({Uint8List value, int receivedAtUs, String id})>[];
      final service = ControllerService(
        t,
        fakeBridgeDeviceId,
        mode: StreamMode.decoded,
        onStreamValue: (value, receivedAtUs, id) {
          seen.add((value: value, receivedAtUs: receivedAtUs, id: id));
        },
      );
      addTearDown(() async {
        await service.dispose();
        await t.dispose();
      });
      await service.start();

      final record = encodeDecodedRecord(
        const DecodedRecord(
          hand: 1,
          sequence: 9,
          rxTimeUs: 0,
          deviceTicks: 200,
          gyro: [0.0, 0.0, 0.0],
          accel: [0.0, 0.0, 0.0],
        ),
      );
      t.emit(fakeBridgeDeviceId, wmrBridgeDecodedCharUuid, record);
      await Future<void>.delayed(Duration.zero);

      // A value that does not parse is still handed to the tap.
      final junk = Uint8List(10);
      t.emit(fakeBridgeDeviceId, wmrBridgeDecodedCharUuid, junk);
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(2));
      expect(seen[0].value, record);
      expect(seen[0].id, fakeBridgeDeviceId);
      expect(seen[1].value, junk);
    },
  );
}
