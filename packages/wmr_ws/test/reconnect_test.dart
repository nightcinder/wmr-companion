import 'dart:async';

import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'fake_pi_server.dart';

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

DecodedRecord record(int hand, int sequence) => DecodedRecord(
  hand: hand,
  sequence: sequence,
  rxTimeUs: 1000000 + sequence * 1000000,
  deviceTicks: 10000000 + sequence * 10000000,
  gyro: const [0.1, -0.2, 0.3],
  accel: const [0.0, 9.8, 0.1],
);

void main() {
  late FakePiServer server;
  late WmrWsTransport transport;
  late String id;
  late ControllerService service;

  setUp(() async {
    server = await FakePiServer.start();
    final endpoint = WmrWsEndpoint(host: '127.0.0.1', port: server.port);
    id = endpoint.resolvedDeviceId;
    transport = WmrWsTransport(endpoints: [endpoint]);
    service = ControllerService(transport, id, mode: StreamMode.decoded);
  });

  tearDown(() async {
    await service.dispose();
    await transport.dispose();
    await server.stop();
  });

  test('a daemon restart after reconnect is a rebaseline, not loss', () async {
    final samples = <DecodedSample>[];
    final sub = service.decodedSamples.listen(samples.add);
    addTearDown(sub.cancel);

    await service.start();
    await waitFor(() => server.activeStream == 'decoded');
    for (final sequence in [100, 101]) {
      server.sendBinary(encodeDecodedRecord(record(0, sequence)));
    }
    await waitFor(() => samples.length == 2);
    expect(service.decodedStats.hands[0].sequenceGaps, 0);

    // The daemon goes away mid-session.
    await server.closeClients(1000, 'restart');
    await waitFor(
      () => transport.helloFor(id) == null,
      reason: 'transport should forget the closed session',
    );

    // Reconnect to the same endpoint and re-run the service start, as the BLE
    // path requires. The daemon starts its sequences at 1 again.
    await service.start();
    await waitFor(() => server.activeStream == 'decoded');
    for (final sequence in [1, 2, 3]) {
      server.sendBinary(encodeDecodedRecord(record(0, sequence)));
    }
    await waitFor(() => samples.length == 5);

    final stats = service.decodedStats;
    expect(stats.hands[0].records, 5);
    expect(stats.hands[0].sequenceGaps, 0, reason: 'restart must not be a gap');
    expect(service.decodedStats.parseErrors, 0);
    expect(
      stats.hands[0].windowLoss,
      isNull,
      reason: 'the window is reset on a re-subscribe and has not refilled',
    );
  });

  test(
    'reconnect keeps serving batches after the transport reconnects',
    () async {
      await service.dispose();
      service = ControllerService(transport, id, mode: StreamMode.batched);
      final samples = <DecodedSample>[];
      final sub = service.decodedSamples.listen(samples.add);
      addTearDown(sub.cancel);

      await service.start();
      await waitFor(() => server.activeStream == 'batched');
      server.sendBinary(
        encodeDecodedBatch([encodeDecodedRecord(record(0, 7))]),
      );
      await waitFor(() => samples.length == 1);

      await server.closeClients(1000, 'restart');
      await waitFor(() => transport.helloFor(id) == null);

      await service.start();
      await waitFor(() => server.activeStream == 'batched');
      server.sendBinary(
        encodeDecodedBatch([encodeDecodedRecord(record(0, 1))]),
      );
      await waitFor(() => samples.length == 2);
      expect(service.decodedStats.batches, 2);
      expect(service.decodedStats.hands[0].sequenceGaps, 0);
    },
  );

  test('a second connect on a live session is a no-op', () async {
    await service.start();
    await waitFor(() => server.activeStream == 'decoded');
    await transport.connect(id);
    expect(server.clients, hasLength(1));
  });

  test('disconnect is idempotent', () async {
    await transport.connect(id);
    await transport.disconnect(id);
    await transport.disconnect(id);
    expect(
      await transport.connectionState(id).first,
      BleConnectionState.disconnected,
    );
  });
}
