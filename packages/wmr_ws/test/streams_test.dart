import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/echo_client.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'fake_pi_server.dart';

class StepClock extends MonotonicClock {
  int now = 0;

  @override
  int get nowUs => now;
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

DecodedRecord record(int hand, int sequence, {int deviceTicks = 1000}) =>
    DecodedRecord(
      hand: hand,
      sequence: sequence,
      rxTimeUs: 500000 + sequence,
      deviceTicks: deviceTicks,
      gyro: const [0.1, -0.2, 0.3],
      accel: const [0.0, 9.8, 0.1],
      temperatureRaw: 42,
      stick: const [100, -100],
      trackpad: const [7, -7],
      trigger: 9,
      battery: 88,
    );

void main() {
  late FakePiServer server;
  late WmrWsTransport transport;
  late String id;

  Future<void> start(
    FakePiOptions options, {
    MonotonicClock? clock,
    int queueSize = 512,
  }) async {
    server = await FakePiServer.start(options);
    final endpoint = WmrWsEndpoint(host: '127.0.0.1', port: server.port);
    id = endpoint.resolvedDeviceId;
    transport = WmrWsTransport(
      endpoints: [endpoint],
      clock: clock,
      queueSize: queueSize,
      requestTimeout: const Duration(seconds: 2),
    );
    await transport.connect(id);
  }

  tearDown(() async {
    await transport.dispose();
    await server.stop();
  });

  test('subscribe sends the stream name and delivers FF12 records', () async {
    await start(const FakePiOptions());
    final notifications = <BleNotification>[];
    final sub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeDecodedCharUuid)
        .listen(notifications.add);
    addTearDown(sub.cancel);
    await waitFor(() => server.activeStream == 'decoded');
    expect(server.messagesOfType('subscribe').single['stream'], 'decoded');

    final bytes = encodeDecodedRecord(record(0, 5));
    server.sendBinary(bytes);
    await waitFor(() => notifications.isNotEmpty);
    expect(notifications.single.value, bytes);
    final parsed = parseDecodedRecord(notifications.single.value).record!;
    expect(parsed.sequence, 5);
    expect(parsed.gyro[0], closeTo(0.1, 1e-6));
    expect(parsed.gyro[1], closeTo(-0.2, 1e-6));
    expect(parsed.gyro[2], closeTo(0.3, 1e-6));
  });

  test('switching stream unsubscribes first, then subscribes', () async {
    await start(const FakePiOptions());
    final decoded = <BleNotification>[];
    final batched = <BleNotification>[];
    final decodedSub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeDecodedCharUuid)
        .listen(decoded.add);
    addTearDown(decodedSub.cancel);
    await waitFor(() => server.activeStream == 'decoded');

    final batchedSub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(batched.add);
    addTearDown(batchedSub.cancel);
    await waitFor(() => server.activeStream == 'batched');

    final types = server.messages.map((m) => m['type']).toList();
    expect(types, ['subscribe', 'unsubscribe', 'subscribe']);
    expect(server.messagesOfType('subscribe').last['stream'], 'batched');

    server.sendBinary(encodeDecodedBatch([encodeDecodedRecord(record(1, 6))]));
    await waitFor(() => batched.isNotEmpty);
    expect(decoded, isEmpty, reason: 'the old stream must be closed');
  });

  test('stream_active maps to BleStreamException(otherStreamActive)', () async {
    await start(const FakePiOptions(subscribeError: 'stream_active'));
    final errors = <Object>[];
    final sub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid)
        .listen((_) {}, onError: errors.add);
    addTearDown(sub.cancel);
    await waitFor(() => errors.isNotEmpty);
    final error = errors.single;
    expect(error, isA<BleStreamException>());
    expect(
      (error as BleStreamException).kind,
      BleStreamFaultKind.otherStreamActive,
    );
    expect(error.characteristicUuid, wmrBridgeStreamCharUuid);
  });

  test('ControllerService maps stream_active to its mode fault', () async {
    await start(const FakePiOptions(subscribeError: 'stream_active'));
    final service = ControllerService(transport, id, mode: StreamMode.decoded);
    addTearDown(service.dispose);
    await service.start();
    await waitFor(() => service.fault != null);
    expect(service.fault?.kind, ModeFaultKind.otherStreamActive);
  });

  test('unsubscribe reaches the daemon and closes the stream', () async {
    await start(const FakePiOptions());
    final done = Completer<void>();
    final sub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeDecodedCharUuid)
        .listen((_) {}, onDone: done.complete);
    addTearDown(sub.cancel);
    await waitFor(() => server.activeStream == 'decoded');
    await transport.unsubscribe(
      id,
      wmrBridgeServiceUuid,
      wmrBridgeDecodedCharUuid,
    );
    await done.future;
    expect(server.messagesOfType('unsubscribe'), hasLength(1));
    expect(server.activeStream, isNull);
  });

  test('reassembly: FF11 fragments become one frame with both hands', () async {
    await start(const FakePiOptions());
    final service = ControllerService(transport, id, mode: StreamMode.raw);
    addTearDown(service.dispose);
    final frames = <ReceivedFrame>[];
    final sub = service.frames.listen(frames.add);
    addTearDown(sub.cancel);
    await service.start();
    await waitFor(() => server.activeStream == 'raw');

    final left = WmrFrame(
      hand: wmrHandLeft,
      sequence: 41,
      data: Uint8List.fromList(List<int>.generate(46, (i) => (i * 3) & 0xff)),
    );
    final right = WmrFrame(
      hand: wmrHandRight,
      sequence: 42,
      data: Uint8List.fromList(List<int>.generate(46, (i) => (i * 5) & 0xff)),
    );
    for (final fragment in encodeFrame(left, 32)) {
      server.sendBinary(fragment);
    }
    for (final fragment in encodeFrame(right, 32)) {
      server.sendBinary(fragment);
    }
    await waitFor(() => frames.length == 2);
    expect(frames[0].frame, left);
    expect(frames[0].bridgeId, id);
    expect(frames[1].frame, right);
    expect(service.stats.hands[0].frames, 1);
    expect(service.stats.hands[1].frames, 1);
    expect(service.stats.hands[0].gaps, 0);
  });

  test('FF14 batches reach the same decoded pipeline as FF12', () async {
    await start(const FakePiOptions());
    final service = ControllerService(transport, id, mode: StreamMode.batched);
    addTearDown(service.dispose);
    final samples = <DecodedSample>[];
    final sub = service.decodedSamples.listen(samples.add);
    addTearDown(sub.cancel);
    await service.start();
    await waitFor(() => server.activeStream == 'batched');

    final records = [
      encodeDecodedRecord(record(0, 10, deviceTicks: 1000)),
      encodeDecodedRecord(record(1, 11, deviceTicks: 2000)),
    ];
    server.sendBinary(encodeDecodedBatch(records));
    await waitFor(() => samples.length == 2);
    expect(samples[0].record.sequence, 10);
    expect(samples[0].record.stick, [100, -100]);
    expect(samples[1].record.hand, 1);
    expect(service.decodedStats.batches, 1);
    expect(service.decodedStats.batchRecords, 2);
    expect(service.decodedStats.hands[0].records, 1);
    expect(service.decodedStats.hands[1].records, 1);
    expect(service.decodedStats.parseErrors, 0);
  });

  test('a paused consumer drops the newest frames and counts them', () async {
    await start(const FakePiOptions(), queueSize: 4);
    final received = <BleNotification>[];
    final sub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
        .listen(received.add);
    addTearDown(sub.cancel);
    await waitFor(() => server.activeStream == 'batched');

    sub.pause();
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 10; i++) {
      server.sendBinary([i]);
    }
    await waitFor(() => transport.statsFor(id).payloadMessages == 10);
    expect(transport.statsFor(id).droppedByQueue, 6);
    expect(received, isEmpty);

    sub.resume();
    await waitFor(() => received.length == 4);
    expect(received.map((n) => n.value.single).toList(), [
      0,
      1,
      2,
      3,
    ], reason: 'the queue keeps the oldest frames and drops the newest');
  });

  test(
    'receivedAtUs is the socket arrival time, not the delivery time',
    () async {
      final clock = StepClock()..now = 1000;
      await start(const FakePiOptions(), clock: clock, queueSize: 4);
      final received = <BleNotification>[];
      final sub = transport
          .subscribe(id, wmrBridgeServiceUuid, wmrBridgeDecodedCharUuid)
          .listen(received.add);
      addTearDown(sub.cancel);
      await waitFor(() => server.activeStream == 'decoded');

      sub.pause();
      await Future<void>.delayed(Duration.zero);
      clock.now = 2000;
      server.sendBinary(encodeDecodedRecord(record(0, 1)));
      await waitFor(() => transport.statsFor(id).payloadMessages == 1);

      // The frame has left the socket and is queued. Time moves on; delivery
      // must keep the arrival stamp.
      clock.now = 900000;
      sub.resume();
      await waitFor(() => received.isNotEmpty);
      expect(received.single.receivedAtUs, 2000);
      expect(clock.nowUs, 900000);
    },
  );

  test('EchoClient round-trips over the JSON ping/pong', () async {
    await start(const FakePiOptions());
    final echo = EchoClient(transport, id);
    addTearDown(echo.dispose);
    expect(await echo.start(), isTrue);
    expect(echo.support, EchoSupport.supported);
    final result = await echo.ping();
    expect(result.failure, isNull);
    final sample = result.sample!;
    expect(sample.answer.pingId, 1);
    expect(sample.answer.rxTimeUs, 123456789);
    expect(sample.rttUs, sample.endToEndUs);
    expect(echo.answered, 1);
  });
}
