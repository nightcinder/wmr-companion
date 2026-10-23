import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';

const id1 = 'bridge-left';
const id2 = 'bridge-right';

void main() {
  late FakeBleAdapter adapter;
  late UniversalBleTransport transport;

  setUp(() {
    adapter = FakeBleAdapter();
    transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(milliseconds: 30),
    );
  });

  tearDown(() => transport.dispose());

  test('connects to multiple bridges independently', () async {
    await transport.connect(id1);
    expect(
      await transport.connectionState(id1).first,
      BleConnectionState.connected,
    );
    expect(transport.statusFor(id1).phase, BleLinkPhase.ready);

    await transport.connect(id2);
    expect(
      await transport.connectionState(id2).first,
      BleConnectionState.connected,
    );
    expect(transport.statusFor(id2).phase, BleLinkPhase.ready);

    // Both MTUs recorded
    expect(transport.negotiatedMtu(id1), 185);
    expect(transport.negotiatedMtu(id2), 185);

    // Both connectionInfos available
    final info1 = await transport.connectionInfo(id1);
    final info2 = await transport.connectionInfo(id2);
    expect(info1.mtu, 185);
    expect(info2.mtu, 185);
  });

  test(
    'subscribeMultiple merges notifications from multiple devices',
    () async {
      await transport.connect(id1);
      await transport.connect(id2);

      final merged = transport.subscribeMultiple(
        [id1, id2],
        wmrBridgeServiceUuid,
        wmrBridgeStreamCharUuid,
      );

      final received = <BleNotification>[];
      final sub = merged.listen(received.add);

      // Allow subscribe _serial to run
      await pumpEventQueue();

      adapter.emitNotification(wmrBridgeStreamCharUuid, [
        0x52,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x2e,
        0x00,
        0x00,
        0x00,
        0x2e,
        0x00,
      ], deviceId: id1);
      adapter.emitNotification(wmrBridgeStreamCharUuid, [
        0x52,
        0x01,
        0x01,
        0x00,
        0x00,
        0x00,
        0x2e,
        0x00,
        0x00,
        0x00,
        0x2e,
        0x00,
      ], deviceId: id2);

      await pumpEventQueue();

      expect(received.length, 2);
      expect(received[0].value[1], 0); // Hand 0 (Left)
      expect(received[1].value[1], 1); // Hand 1 (Right)

      await sub.cancel();
    },
  );

  test(
    'disconnecting one bridge leaves the other connected and active',
    () async {
      await transport.connect(id1);
      await transport.connect(id2);

      expect(
        await transport.connectionState(id1).first,
        BleConnectionState.connected,
      );
      expect(
        await transport.connectionState(id2).first,
        BleConnectionState.connected,
      );

      await transport.disconnect(id1);

      expect(
        await transport.connectionState(id1).first,
        BleConnectionState.disconnected,
      );
      expect(transport.statusFor(id1).phase, BleLinkPhase.disconnected);

      expect(
        await transport.connectionState(id2).first,
        BleConnectionState.connected,
      );
      expect(transport.statusFor(id2).phase, BleLinkPhase.ready);
    },
  );
}
