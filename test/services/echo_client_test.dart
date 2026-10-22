import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/ble_transport.dart';
import 'package:wmr_companion/ble/fake_transport.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/protocol/echo.dart';
import 'package:wmr_companion/protocol/gatt.dart';
import 'package:wmr_companion/services/echo_client.dart';

class _Clock implements MonotonicClock {
  int now = 5000000;

  @override
  int get nowUs => now;
}

void main() {
  late _Clock clock;
  late FakeTransport transport;
  late EchoClient client;

  Future<void> setUpClient({
    FakeDevice device = fakeBridgeDevice,
    Duration timeout = const Duration(milliseconds: 40),
    bool echoEnabled = true,
  }) async {
    clock = _Clock();
    transport = FakeTransport(devices: [device], clock: clock);
    FakeWmrBridge(transport, echoEnabled: echoEnabled);
    await transport.connect(device.id);
    client = EchoClient(transport, device.id, timeout: timeout);
  }

  /// Moves the phone clock while the write is "in flight", so the answer is
  /// stamped [us] after the request.
  void roundTripTakes(int us) {
    final inner = transport.onWrite!;
    transport.onWrite = (w) {
      clock.now += us;
      return inner(w);
    };
  }

  tearDown(() async {
    await client.dispose();
    await transport.dispose();
  });

  test(
    'subscribes to FF15 only and sends a write-without-response ping',
    () async {
      await setUpClient();
      expect(await client.start(), isTrue);
      expect(client.support, EchoSupport.supported);
      expect(transport.cccLog, ['on $wmrBridgeEchoCharUuid']);

      roundTripTakes(8000);
      final r = await client.ping();
      final w = transport.writes.single;
      expect(w.characteristicUuid, wmrBridgeEchoCharUuid);
      expect(w.withoutResponse, isTrue);
      expect(w.value, encodeEchoRequest(1));

      final s = r.sample!;
      expect(s.pingId, 1);
      expect(s.t1Us, 5000000);
      expect(s.t4Us, 5008000);
      expect(s.endToEndUs, 8000);
      expect(s.answer.turnaroundUs, 300);
      expect(s.rttUs, 7700); // (t4 - t1) - turnaround
      expect(client.answered, 1);
      expect(client.sent, 1);
    },
  );

  test('ping ids count up from 1', () async {
    await setUpClient();
    await client.start();
    final ids = <int>[];
    for (var i = 0; i < 3; i++) {
      ids.add((await client.ping()).sample!.pingId);
    }
    expect(ids, [1, 2, 3]);
  });

  test('offset estimate follows the spec formula', () {
    const s = EchoSample(
      t1Us: 1000,
      t1DoneUs: 1100,
      t4Us: 1600,
      answer: EchoAnswer(
        pingId: 1,
        rxTimeUs: 9000,
        turnaroundUs: 100,
        queueDepth: 0,
      ),
    );
    // ((t2 - t1) + (t3 - t4)) / 2 = ((9000-1000) + (9100-1600)) / 2
    expect(s.offsetUs, 7750);
    expect(s.rttUs, 500);
  });

  test('no answer: timeout is counted, a late answer is stale', () async {
    await setUpClient(echoEnabled: false);
    await client.start();
    final r = await client.ping();
    expect(r.failure, EchoFailure.timeout);
    expect(client.timeouts, 1);

    // The answer arrives after the client gave up.
    transport.emit(
      fakeBridgeDeviceId,
      wmrBridgeEchoCharUuid,
      encodeEchoAnswer(
        const EchoAnswer(
          pingId: 1,
          rxTimeUs: 1,
          turnaroundUs: 1,
          queueDepth: 0,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.stale, 1);
    expect(client.answered, 0);
  });

  test('an answer with another ping id does not complete the ping', () async {
    await setUpClient(echoEnabled: false);
    await client.start();
    final pending = client.ping();
    await Future<void>.delayed(Duration.zero);
    transport.emit(
      fakeBridgeDeviceId,
      wmrBridgeEchoCharUuid,
      encodeEchoAnswer(
        const EchoAnswer(
          pingId: 99,
          rxTimeUs: 1,
          turnaroundUs: 1,
          queueDepth: 0,
        ),
      ),
    );
    transport.emit(fakeBridgeDeviceId, wmrBridgeEchoCharUuid, [1, 2, 3]);
    expect((await pending).failure, EchoFailure.timeout);
    expect(client.stale, 1);
    expect(client.badAnswers, 1);
  });

  test('one ping at a time', () async {
    await setUpClient(echoEnabled: false);
    await client.start();
    final first = client.ping();
    await Future<void>.delayed(Duration.zero);
    expect(client.busy, isTrue);
    expect((await client.ping()).failure, EchoFailure.busy);
    expect(client.skipped, 1);
    expect(transport.writes, hasLength(1));
    await first;
  });

  test('a failed write is its own outcome', () async {
    await setUpClient();
    await client.start();
    transport.onWrite = (_) => throw StateError('gatt busy');
    final r = await client.ping();
    expect(r.failure, EchoFailure.writeFailed);
    expect(client.lastError, isA<StateError>());
    expect(client.busy, isFalse);
  });

  test('a bridge without FF15 is detected, nothing is subscribed', () async {
    await setUpClient(
      device: const FakeDevice(
        id: fakeBridgeDeviceId,
        name: wmrBridgeDeviceName,
        services: [
          BleServiceInfo(
            uuid: wmrBridgeServiceUuid,
            characteristicUuids: [
              wmrBridgeStreamCharUuid,
              wmrBridgeDecodedCharUuid,
              wmrBridgeBatchedCharUuid,
            ],
          ),
        ],
      ),
    );
    expect(await client.start(), isFalse);
    expect(client.support, EchoSupport.unsupported);
    expect(transport.cccLog, isEmpty);
    expect((await client.ping()).failure, EchoFailure.cancelled);
    expect(transport.writes, isEmpty);
  });

  test(
    'dispose turns FF15 notifications off and ends a waiting ping',
    () async {
      await setUpClient(echoEnabled: false);
      await client.start();
      final pending = client.ping();
      await Future<void>.delayed(Duration.zero);
      await client.dispose();
      expect((await pending).failure, EchoFailure.cancelled);
      expect(transport.cccLog, [
        'on $wmrBridgeEchoCharUuid',
        'off $wmrBridgeEchoCharUuid',
      ]);
    },
  );
}
