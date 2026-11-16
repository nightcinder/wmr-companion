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
  }) async {
    server = await FakePiServer.start();
    final endpoint = WmrWsEndpoint(host: '127.0.0.1', port: server.port);
    id = endpoint.resolvedDeviceId;
    transport = WmrWsTransport(
      endpoints: [endpoint],
      livenessInterval: interval,
      livenessTimeout: timeout,
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
}
