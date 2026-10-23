import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/config_block.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/config_client.dart';

Uint8List _ramp(int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 13 + 5) & 0xff]);

void main() {
  late FakeTransport transport;
  late FakeWmrBridge bridge;

  Future<ConfigClient> setUp0({
    FakeDevice device = fakeBridgeDevice,
    List<Uint8List?> blobs = const [null, null],
    List<ConfigState>? states,
    Duration readyTimeout = const Duration(milliseconds: 200),
  }) async {
    transport = FakeTransport(devices: [device]);
    bridge = FakeWmrBridge(transport, configBlobs: blobs, configStates: states);
    await transport.connect(device.id);
    return ConfigClient(
      transport,
      device.id,
      readyTimeout: readyTimeout,
      pollInterval: const Duration(milliseconds: 10),
    );
  }

  tearDown(() => transport.dispose());

  test('reads a multi-window blob for each hand and checks the CRC', () async {
    final left = _ramp(7147); // the size reported for LEFT on hardware
    final right = _ramp(7148);
    final client = await setUp0(blobs: [left, right]);

    final l = await client.read(0);
    expect(l.failure, isNull);
    expect(l.blob, left);
    expect(l.crc, crc32(left));
    final r = await client.read(1);
    expect(r.blob, right);

    // 15 windows for 7147 bytes (496 each), each a cursor write + a read.
    expect((7147 / wmrConfigWindowMax).ceil(), 15);
    final cursorWrites = transport.writes.where(
      (w) => w.characteristicUuid == wmrBridgeConfigCharUuid,
    );
    expect(cursorWrites.first.value, [0, 0, 0, 0, 0]);
    expect(cursorWrites.first.withoutResponse, isFalse);
  });

  test('a blob of exactly one window and an empty-window edge', () async {
    final exact = _ramp(wmrConfigWindowMax);
    final client = await setUp0(blobs: [exact, null]);
    expect((await client.read(0)).blob, exact);
    transport.reads.clear();
    final again = await client.read(0);
    expect(again.blob, exact);
    expect(transport.reads, hasLength(1));
  });

  test('waits while the bridge is still reading, then succeeds', () async {
    final blob = _ramp(600);
    final client = await setUp0(
      blobs: [blob, null],
      states: [ConfigState.reading, ConfigState.notRead],
    );
    Future<void>.delayed(
      const Duration(milliseconds: 50),
      () => bridge.configStates[0] = ConfigState.ready,
    );
    final r = await client.read(0);
    expect(r.blob, blob);
  });

  test('reports notReady when the block never becomes ready', () async {
    final client = await setUp0(
      states: [ConfigState.notRead, ConfigState.notRead],
    );
    final r = await client.read(1);
    expect(r.failure, ConfigReadFailure.notReady);
    expect(r.state, ConfigState.notRead);
  });

  test('reports the bridge failing to read the controller', () async {
    final client = await setUp0(
      states: [ConfigState.failed, ConfigState.notRead],
    );
    final r = await client.read(0);
    expect(r.failure, ConfigReadFailure.bridgeFailed);
  });

  test('detects a corrupted blob by CRC', () async {
    final blob = _ramp(1200);
    final client = await setUp0(blobs: [blob, null]);
    final inner = transport.onRead!;
    // Flip one data byte in the second window only.
    var n = 0;
    transport.onRead = (id, c) async {
      final v = Uint8List.fromList(await inner(id, c));
      if (++n == 2) v[20] ^= 0x01;
      return v;
    };
    final r = await client.read(0);
    expect(r.failure, ConfigReadFailure.crcMismatch);
  });

  test('windows that disagree are reported, not stitched together', () async {
    final client = await setUp0(blobs: [_ramp(1200), null]);
    final inner = transport.onRead!;
    var n = 0;
    transport.onRead = (id, c) async {
      final v = Uint8List.fromList(await inner(id, c));
      if (++n == 2) {
        ByteData.sublistView(v).setUint32(4, 1201, Endian.little); // total_len
      }
      return v;
    };
    final r = await client.read(0);
    expect(r.failure, ConfigReadFailure.inconsistent);
  });

  test('a bridge without FF13 is reported as unsupported', () async {
    const old = FakeDevice(
      id: 'old',
      name: wmrBridgeDeviceName,
      services: [
        BleServiceInfo(
          uuid: wmrBridgeServiceUuid,
          characteristicUuids: [wmrBridgeStreamCharUuid, wmrBridgeEchoCharUuid],
        ),
      ],
    );
    final client = await setUp0(device: old);
    final r = await client.read(0);
    expect(r.failure, ConfigReadFailure.unsupported);
    expect(transport.writes, isEmpty);
  });

  test('a failing GATT call is a transport failure with lastError', () async {
    final client = await setUp0(blobs: [_ramp(100), null]);
    transport.onRead = (id, c) => throw StateError('gatt read failed');
    final r = await client.read(0);
    expect(r.failure, ConfigReadFailure.transport);
    expect(client.lastError, isA<StateError>());
  });
}
