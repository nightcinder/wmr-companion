import 'dart:async';

import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/echo.dart';
import 'package:wmr_core/protocol/gatt.dart';
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

void main() {
  late FakePiServer server;
  late WmrWsTransport transport;
  late String id;

  Future<void> start({
    Duration interval = const Duration(milliseconds: 100),
    Duration timeout = const Duration(milliseconds: 300),
    Duration silenceProbeDelay = Duration.zero,
  }) async {
    server = await FakePiServer.start();
    final endpoint = WmrWsEndpoint(host: '127.0.0.1', port: server.port);
    id = endpoint.resolvedDeviceId;
    transport = WmrWsTransport(
      endpoints: [endpoint],
      livenessInterval: interval,
      livenessTimeout: timeout,
      silenceProbeDelay: silenceProbeDelay,
    );
  }

  Iterable<Map<String, Object?>> livenessPings() => server
      .messagesOfType('ping')
      .where((message) => (message['id']! as int) >= wmrWsLivenessPingIdBase);

  tearDown(() async {
    await transport.dispose();
    await server.stop();
  });

  test('probes a peer that answers and stays connected', () async {
    await start();
    await transport.connect(id);
    final states = <BleConnectionState>[];
    final sub = transport.connectionState(id).listen(states.add);
    addTearDown(sub.cancel);

    await waitFor(() => livenessPings().length >= 3);
    expect(states, isNot(contains(BleConnectionState.disconnected)));
    expect(transport.helloFor(id), isNotNull);

    final probes = livenessPings().toList();
    expect(probes.map((probe) => probe['t']), everyElement(isA<int>()));
    expect(
      probes.map((probe) => probe['id']).toSet(),
      hasLength(probes.length),
      reason: 'each probe must carry a fresh id',
    );
  });

  test('closes a silent peer and reports disconnected in time', () async {
    await start();
    await transport.connect(id);
    final states = <BleConnectionState>[];
    final sub = transport.connectionState(id).listen(states.add);
    addTearDown(sub.cancel);
    await waitFor(() => livenessPings().isNotEmpty);

    // The socket stays open and writable, but nothing behind it answers: the
    // half-open peer a TCP stack cannot detect on its own.
    server.answerPings = false;
    final silentAt = DateTime.now();
    await waitFor(
      () => states.contains(BleConnectionState.disconnected),
      reason: 'a half-open socket was not detected',
    );

    expect(
      DateTime.now().difference(silentAt),
      lessThanOrEqualTo(const Duration(milliseconds: 1500)),
      reason: 'detection must stay inside the 1500 ms liveness budget',
    );
    expect(transport.helloFor(id), isNull);
    await waitFor(
      () => server.clients.isEmpty,
      reason: 'the silent socket was left open',
    );
  });

  test('liveness pongs never become FF15 echo answers', () async {
    await start();
    await transport.connect(id);
    final answers = <BleNotification>[];
    final sub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
        .listen(answers.add);
    addTearDown(sub.cancel);

    await waitFor(() => livenessPings().length >= 2);
    expect(answers, isEmpty, reason: 'a keepalive pong reached the echo sink');

    await transport.write(
      id,
      wmrBridgeServiceUuid,
      wmrBridgeEchoCharUuid,
      encodeEchoRequest(9),
      withoutResponse: true,
    );
    await waitFor(() => answers.isNotEmpty);
    expect(parseEchoAnswer(answers.single.value).answer!.pingId, 9);
  });

  test('a non-positive interval disables the probes', () async {
    await start(interval: Duration.zero);
    await transport.connect(id);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(livenessPings(), isEmpty);
    expect(transport.helloFor(id), isNotNull);
  });

  group('silence-aware liveness (S1-S5)', () {
    test('S1: active binary stream resets silence timer and stays on TCP', () async {
      await start(
        interval: const Duration(milliseconds: 400),
        timeout: const Duration(milliseconds: 600),
        silenceProbeDelay: const Duration(milliseconds: 100),
      );
      await transport.connect(id);
      final states = <BleConnectionState>[];
      final sub = transport.connectionState(id).listen(states.add);
      addTearDown(sub.cancel);
      final frames = <BleNotification>[];
      final streamSub = transport
          .subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
          .listen(frames.add);
      addTearDown(streamSub.cancel);
      await waitFor(() => server.messagesOfType('subscribe').isNotEmpty);

      // Stream binary frames faster than silenceProbeDelay (every 30 ms for 240 ms):
      // silence timer keeps resetting, so no silence probe fires before 400 ms.
      for (var i = 0; i < 8; i++) {
        server.sendBinary([1, 2, 3, i]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      expect(frames.length, 8);
      expect(transport.statsFor(id).payloadMessages, 8);
      expect(livenessPings(), isEmpty);
      expect(states, isNot(contains(BleConnectionState.disconnected)));
      expect(transport.helloFor(id), isNotNull);
    });

    test('S2: transient silence triggers probe within 100 ms and pong before 600 ms stays connected', () async {
      await start(
        interval: const Duration(milliseconds: 250),
        timeout: const Duration(milliseconds: 600),
        silenceProbeDelay: const Duration(milliseconds: 100),
      );
      await transport.connect(id);
      final states = <BleConnectionState>[];
      final sub = transport.connectionState(id).listen(states.add);
      addTearDown(sub.cancel);
      final streamSub = transport
          .subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
          .listen((_) {});
      addTearDown(streamSub.cancel);
      await waitFor(() => server.messagesOfType('subscribe').isNotEmpty);

      server.sendBinary([1, 2, 3]);
      await waitFor(() => transport.statsFor(id).payloadMessages == 1);
      final lastFrameAt = DateTime.now();

      await waitFor(() => livenessPings().isNotEmpty);
      final probeDelay = DateTime.now().difference(lastFrameAt);
      expect(probeDelay, lessThanOrEqualTo(const Duration(milliseconds: 180)));

      // Pong is answered automatically by FakePiServer (< 600 ms), so stay connected.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(states, isNot(contains(BleConnectionState.disconnected)));
      expect(transport.helloFor(id), isNotNull);
    });

    test('S3: sustained half-open blackout disconnects within 750 ms of last TCP record', () async {
      await start(
        interval: const Duration(milliseconds: 250),
        timeout: const Duration(milliseconds: 600),
        silenceProbeDelay: const Duration(milliseconds: 100),
      );
      await transport.connect(id);
      final states = <BleConnectionState>[];
      final sub = transport.connectionState(id).listen(states.add);
      addTearDown(sub.cancel);
      final streamSub = transport
          .subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
          .listen((_) {});
      addTearDown(streamSub.cancel);
      await waitFor(() => server.messagesOfType('subscribe').isNotEmpty);

      server.answerPings = false;
      server.sendBinary([1, 2, 3]);
      await waitFor(() => transport.statsFor(id).payloadMessages == 1);
      final lastFrameAt = DateTime.now();

      await waitFor(
        () => states.contains(BleConnectionState.disconnected),
        reason: 'half-open stream blackout did not disconnect',
      );
      expect(
        DateTime.now().difference(lastFrameAt),
        lessThanOrEqualTo(const Duration(milliseconds: 750)),
      );
    });

    test('S4: silence while liveness ping is already pending does not reset or extend deadline', () async {
      await start(
        interval: const Duration(milliseconds: 80),
        timeout: const Duration(milliseconds: 300),
        silenceProbeDelay: const Duration(milliseconds: 40),
      );
      await transport.connect(id);
      final states = <BleConnectionState>[];
      final sub = transport.connectionState(id).listen(states.add);
      addTearDown(sub.cancel);
      final streamSub = transport
          .subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
          .listen((_) {});
      addTearDown(streamSub.cancel);
      await waitFor(() => server.messagesOfType('subscribe').isNotEmpty);

      // Stop answering pings and wait for the periodic liveness ping to arm its 300 ms deadline.
      server.answerPings = false;
      await waitFor(() => livenessPings().length == 1);
      final pingSentAt = DateTime.now();

      // Send one binary frame right after the ping was sent, then go silent so
      // silenceProbeDelay (40 ms) fires while the ping is still pending.
      server.sendBinary([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // No second ping should be sent while the first is pending.
      expect(livenessPings().length, 1);

      await waitFor(
        () => states.contains(BleConnectionState.disconnected),
        reason: 'pending liveness deadline was extended or missed',
      );
      final elapsed = DateTime.now().difference(pingSentAt);
      expect(elapsed, lessThan(const Duration(milliseconds: 360)));
    });

    test('S5: intentional disconnect and dispose cancel silence and liveness timers', () async {
      await start(
        interval: const Duration(milliseconds: 100),
        timeout: const Duration(milliseconds: 150),
        silenceProbeDelay: const Duration(milliseconds: 40),
      );
      await transport.connect(id);
      final streamSub = transport
          .subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid)
          .listen((_) {});
      addTearDown(streamSub.cancel);
      await waitFor(() => server.messagesOfType('subscribe').isNotEmpty);

      server.answerPings = false;
      server.sendBinary([1, 2, 3]);
      await waitFor(() => transport.statsFor(id).payloadMessages == 1);

      // Disconnect immediately while silence timer is armed.
      await transport.disconnect(id);
      final statesAfter = <BleConnectionState>[];
      final sub = transport.connectionState(id).listen(statesAfter.add);
      addTearDown(sub.cancel);
      final pingCountAtDisconnect = livenessPings().length;

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(livenessPings().length, pingCountAtDisconnect);
      expect(statesAfter, [BleConnectionState.disconnected]);

      await transport.dispose();
    });
  });
}
