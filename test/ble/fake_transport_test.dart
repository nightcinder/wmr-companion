import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/ble_transport.dart';
import 'package:wmr_companion/ble/fake_transport.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/protocol/gatt.dart';

void main() {
  late FakeTransport t;

  setUp(() => t = FakeTransport(devices: const [fakeBridgeDevice]));
  tearDown(() => t.dispose());

  test('scan filters by service UUID, case-insensitively', () async {
    expect(await t.scan().toList(), hasLength(1));
    expect(
      await t.scan(withServices: [wmrBridgeServiceUuid.toUpperCase()]).toList(),
      hasLength(1),
    );
    expect(
      await t
          .scan(withServices: ['0000abcd-0000-1000-8000-00805f9b34fb'])
          .toList(),
      isEmpty,
    );
  });

  test('requires a connection for GATT operations', () {
    expect(
      () => t.subscribe(
        fakeBridgeDeviceId,
        wmrBridgeServiceUuid,
        wmrBridgeStreamCharUuid,
      ),
      throwsStateError,
    );
    expect(t.connect('nope'), throwsStateError);
  });

  test('emit delivers timestamped notifications to subscribers', () async {
    await t.connect(fakeBridgeDeviceId);
    expect(t.emit(fakeBridgeDeviceId, wmrBridgeStreamCharUuid, [1]), isFalse);

    final received = <BleNotification>[];
    final sub = t
        .subscribe(
          fakeBridgeDeviceId,
          wmrBridgeServiceUuid,
          wmrBridgeStreamCharUuid,
        )
        .listen(received.add);
    expect(
      t.emit(fakeBridgeDeviceId, wmrBridgeStreamCharUuid.toUpperCase(), [1, 2]),
      isTrue,
    );
    t.emit(fakeBridgeDeviceId, wmrBridgeStreamCharUuid, [3]);
    await Future<void>.delayed(Duration.zero);

    expect(received.map((n) => n.value), [
      [1, 2],
      [3],
    ]);
    expect(
      received[1].receivedAtUs,
      greaterThanOrEqualTo(received[0].receivedAtUs),
    );
    await sub.cancel();
  });

  test('records writes and calls onWrite', () async {
    await t.connect(fakeBridgeDeviceId);
    FakeWrite? seen;
    t.onWrite = (w) => seen = w;
    await t.write(
      fakeBridgeDeviceId,
      wmrBridgeServiceUuid,
      wmrBridgeStreamCharUuid,
      Uint8List.fromList([9]),
      withoutResponse: true,
    );
    expect(t.writes.single.value, [9]);
    expect(seen?.withoutResponse, isTrue);
  });

  test('connection state stream starts with the current state', () async {
    final states = <BleConnectionState>[];
    final sub = t.connectionState(fakeBridgeDeviceId).listen(states.add);
    await Future<void>.delayed(Duration.zero);
    await t.connect(fakeBridgeDeviceId);
    await t.disconnect(fakeBridgeDeviceId);
    await Future<void>.delayed(Duration.zero);
    expect(states, [
      BleConnectionState.disconnected,
      BleConnectionState.connected,
      BleConnectionState.disconnected,
    ]);
    await sub.cancel();
  });

  test('connectionInfo reports the fake MTU', () async {
    await t.connect(fakeBridgeDeviceId);
    expect((await t.connectionInfo(fakeBridgeDeviceId)).mtu, 247);
  });
}
