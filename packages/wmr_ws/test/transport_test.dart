import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/echo.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/config_client.dart';
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

Future<void> pump([int times = 3]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakePiServer server;
  late WmrWsTransport transport;
  late WmrWsEndpoint endpoint;
  late String id;

  Future<void> start([FakePiOptions? options]) async {
    server = await FakePiServer.start(options);
    endpoint = WmrWsEndpoint(host: '127.0.0.1', port: server.port);
    id = endpoint.resolvedDeviceId;
    transport = WmrWsTransport(
      endpoints: [endpoint],
      authTimeout: const Duration(milliseconds: 200),
      handshakeTimeout: const Duration(milliseconds: 400),
      requestTimeout: const Duration(seconds: 2),
    );
  }

  tearDown(() async {
    await transport.dispose();
    await server.stop();
  });

  test('scan reports the configured endpoint, with no invented RSSI', () async {
    await start();
    final results = await transport.scan().toList();
    expect(results, hasLength(1));
    expect(results.single.deviceId, id);
    expect(results.single.name, 'WMR Bridge (127.0.0.1)');
    expect(results.single.rssi, isNull);
    expect(results.single.serviceUuids, [wmrBridgeServiceUuid]);
    expect(
      await transport
          .scan(withServices: ['0000180f-0000-1000-8000-00805f9b34fb'])
          .toList(),
      isEmpty,
    );
  });

  test('connect performs the subprotocol handshake', () async {
    await start();
    await transport.connect(id);
    await server.connected;
    expect(server.negotiatedProtocol, 'wmr-wifi-v1');
    expect(transport.helloFor(id)?.version, '0.1.0-test');
    expect(
      await transport.connectionState(id).first,
      BleConnectionState.connected,
    );
  });

  test(
    'connectionInfo maps fragmentCapacity to mtu and nulls the rest',
    () async {
      await start();
      await transport.connect(id);
      final info = await transport.connectionInfo(id);
      expect(info.mtu, 244);
      expect(info.rssi, isNull);
      expect(info.connectionIntervalUs, isNull);
      expect(info.phy, isNull);
    },
  );

  test(
    'discoverServices synthesizes FF10 from hello.streams, no FF13',
    () async {
      await start(const FakePiOptions(streams: ['raw', 'decoded', 'batched']));
      await transport.connect(id);
      final services = await transport.discoverServices(id);
      expect(services, hasLength(1));
      expect(services.single.uuid, wmrBridgeServiceUuid);
      expect(
        services.single.characteristicUuids,
        containsAll([
          wmrBridgeStreamCharUuid,
          wmrBridgeDecodedCharUuid,
          wmrBridgeBatchedCharUuid,
          wmrBridgeEchoCharUuid,
          wmrBridgeVersionCharUuid,
        ]),
      );
      expect(
        services.single.characteristicUuids,
        isNot(contains(wmrBridgeConfigCharUuid)),
      );
    },
  );

  test(
    'discoverServices follows the streams this build actually has',
    () async {
      await start(const FakePiOptions(streams: ['raw']));
      await transport.connect(id);
      final services = await transport.discoverServices(id);
      final chars = services.single.characteristicUuids;
      expect(chars, contains(wmrBridgeStreamCharUuid));
      expect(chars, isNot(contains(wmrBridgeDecodedCharUuid)));
      expect(chars, isNot(contains(wmrBridgeBatchedCharUuid)));
      expect(chars, contains(wmrBridgeEchoCharUuid));
      expect(chars, contains(wmrBridgeVersionCharUuid));
    },
  );

  test('read(FF16) returns hello.version without a round trip', () async {
    await start(const FakePiOptions(version: 'pi-1.2.3'));
    await transport.connect(id);
    final before = server.messages.length;
    final value = await transport.read(
      id,
      wmrBridgeServiceUuid,
      wmrBridgeVersionCharUuid,
    );
    expect(utf8.decode(value), 'pi-1.2.3');
    expect(server.messages.length, before);
  });

  test(
    'read/write on FF13 fail cleanly; ConfigClient reports unsupported',
    () async {
      await start();
      await transport.connect(id);
      await expectLater(
        transport.read(id, wmrBridgeServiceUuid, wmrBridgeConfigCharUuid),
        throwsA(isA<WmrWsUnsupportedException>()),
      );
      await expectLater(
        transport.write(
          id,
          wmrBridgeServiceUuid,
          wmrBridgeConfigCharUuid,
          Uint8List(5),
        ),
        throwsA(isA<WmrWsUnsupportedException>()),
      );
      await expectLater(
        transport.read(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid),
        throwsA(isA<WmrWsUnsupportedException>()),
      );

      final config = ConfigClient(transport, id);
      final result = await config.read(0);
      expect(result.failure, ConfigReadFailure.unsupported);
      expect(result.blob, isNull);
    },
  );

  test('status exposes the daemon counters including dropped', () async {
    await start();
    await transport.connect(id);
    final status = await transport.status(id);
    expect(status.uptimeS, 1.5);
    expect(status.hostTimeUs, 123456789);
    expect(status.hands, hasLength(2));
    expect(status.hands.first.hand, 0);
    expect(status.hands.first.reports, 100);
    expect(status.hands.last.hand, 1);
    expect(status.dropped, 3);
    expect(status.batches, 42);
  });

  group('authentication', () {
    test('sends the token and completes on auth_ok', () async {
      await start(
        const FakePiOptions(authRequired: true, authMode: FakeAuthMode.accept),
      );
      final authed = WmrWsEndpoint(
        host: '127.0.0.1',
        port: server.port,
        token: 'shared-secret',
      );
      final transport2 = WmrWsTransport(endpoints: [authed]);
      addTearDown(transport2.dispose);
      await transport2.connect(authed.resolvedDeviceId);
      expect(server.messagesOfType('auth').single['token'], 'shared-secret');
      expect(server.messagesOfType('auth'), hasLength(1));
    });

    test('rejected auth throws and leaves the link down', () async {
      await start(
        const FakePiOptions(authRequired: true, authMode: FakeAuthMode.reject),
      );
      final authed = WmrWsEndpoint(
        host: '127.0.0.1',
        port: server.port,
        token: 'wrong',
      );
      final transport2 = WmrWsTransport(
        endpoints: [authed],
        authTimeout: const Duration(seconds: 1),
      );
      addTearDown(transport2.dispose);
      await expectLater(
        transport2.connect(authed.resolvedDeviceId),
        throwsA(
          isA<WmrWsAuthException>().having(
            (e) => e.failure,
            'failure',
            WmrWsAuthFailure.rejected,
          ),
        ),
      );
      expect(
        await transport2.connectionState(authed.resolvedDeviceId).first,
        BleConnectionState.disconnected,
      );
    });

    test('silent daemon hits the local auth timeout', () async {
      await start(
        const FakePiOptions(authRequired: true, authMode: FakeAuthMode.ignore),
      );
      final authed = WmrWsEndpoint(
        host: '127.0.0.1',
        port: server.port,
        token: 'token',
      );
      final transport2 = WmrWsTransport(
        endpoints: [authed],
        authTimeout: const Duration(milliseconds: 100),
        handshakeTimeout: const Duration(seconds: 1),
      );
      addTearDown(transport2.dispose);
      await expectLater(
        transport2.connect(authed.resolvedDeviceId),
        throwsA(
          isA<WmrWsAuthException>().having(
            (e) => e.failure,
            'failure',
            WmrWsAuthFailure.timeout,
          ),
        ),
      );
    });

    test('missing token fails before pretending to authenticate', () async {
      await start(const FakePiOptions(authRequired: true));
      await expectLater(
        transport.connect(id),
        throwsA(
          isA<WmrWsAuthException>().having(
            (e) => e.failure,
            'failure',
            WmrWsAuthFailure.noToken,
          ),
        ),
      );
      expect(server.messagesOfType('auth'), isEmpty);
    });
  });

  test('a daemon that never says hello times out', () async {
    await start(const FakePiOptions(sendHello: false));
    await expectLater(
      transport.connect(id),
      throwsA(isA<WmrWsHandshakeException>()),
    );
  });

  test('FF15 ping/pong becomes a 20-byte echo answer', () async {
    await start();
    await transport.connect(id);
    final answers = <BleNotification>[];
    final sub = transport
        .subscribe(id, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
        .listen(answers.add);
    addTearDown(sub.cancel);

    await transport.write(
      id,
      wmrBridgeServiceUuid,
      wmrBridgeEchoCharUuid,
      encodeEchoRequest(7),
      withoutResponse: true,
    );
    await waitFor(() => answers.isNotEmpty);
    final answer = parseEchoAnswer(answers.single.value).answer!;
    expect(answer.pingId, 7);
    expect(answer.rxTimeUs, 123456789);
    expect(answer.turnaroundUs, 0);
    expect(answer.queueDepth, 0);
    final ping = server.messagesOfType('ping').single;
    expect(ping['id'], 7);
    expect(ping['t'], isA<int>());
  });

  test(
    'a binary message with no subscription is counted, not queued',
    () async {
      await start();
      await transport.connect(id);
      server.sendBinary([1, 2, 3]);
      await waitFor(() => transport.statsFor(id).payloadMessages == 1);
      expect(transport.statsFor(id).unexpectedMessages, 1);
    },
  );

  test('socket close moves the connection to disconnected', () async {
    await start();
    await transport.connect(id);
    final states = <BleConnectionState>[];
    final sub = transport.connectionState(id).listen(states.add);
    addTearDown(sub.cancel);
    await server.closeClients(1000, 'bye');
    await waitFor(
      () => states.isNotEmpty && states.last == BleConnectionState.disconnected,
      reason: 'expected a disconnected state, saw $states',
    );
    expect(() => transport.statsFor(id), returnsNormally);
  });
}
