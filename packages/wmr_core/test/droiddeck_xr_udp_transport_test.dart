import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_core/services/droiddeck_xr_queued_transport.dart';
import 'package:wmr_core/services/droiddeck_xr_transport.dart';

const _token = 0x12345678;

class FakeTransport implements DroidDeckXrNonBlockingTransport {
  FakeTransport({this.accept = true});

  bool accept;
  bool closed = false;
  final sent = <Uint8List>[];

  @override
  bool trySend(Uint8List packet) {
    if (closed || !accept) return false;
    sent.add(Uint8List.fromList(packet));
    return true;
  }

  @override
  Future<void> send(Uint8List packet) async {
    if (!trySend(packet)) {
      throw const DroidDeckXrTransportException('write failed');
    }
  }

  @override
  Future<void> close() async => closed = true;
}

Uint8List _packet({
  int length = DroidDeckXrProtocol.packetBytes,
  int fill = 0,
}) => Uint8List.fromList(List<int>.filled(length, fill));

Uint8List _input() => encodeDroidDeckXrInput(sequence: 1, timeNs: 1000000000);

Uint8List _claim() => encodeDroidDeckXrClaim(
  claim: const DroidDeckXrClaim(vendorId: 0x045e, productId: 0x02ea),
  sequence: 2,
  timeNs: 1000000000,
);

int _tokenAt(Uint8List packet) =>
    ByteData.sublistView(packet)
        .getUint32(DroidDeckXrProtocol.tokenOffset, Endian.little);

/// Collects [count] datagrams from [socket].
Future<List<Uint8List>> _receive(RawDatagramSocket socket, int count) {
  final received = <Uint8List>[];
  final done = Completer<List<Uint8List>>();
  late StreamSubscription<RawSocketEvent> subscription;
  subscription = socket.listen((_) {
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) break;
      received.add(datagram.data);
      if (received.length == count) {
        if (!done.isCompleted) done.complete(received);
        unawaited(subscription.cancel());
        break;
      }
    }
  });
  return done.future.timeout(const Duration(seconds: 2));
}

void main() {
  test('UDP send and trySend stamp the token, claims included', () async {
    final receiver = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(receiver.close);
    final transport = await DroidDeckXrUdpTransport.connect(
      token: _token,
      port: receiver.port,
    );
    addTearDown(transport.close);

    final input = _input();
    final claim = _claim();
    final datagrams = _receive(receiver, 2);

    await transport.send(input);
    expect(transport.trySend(claim), isTrue);

    final received = await datagrams;
    expect(received, hasLength(2));
    expect(received[0], hasLength(DroidDeckXrProtocol.packetBytes));
    expect(received[1], hasLength(DroidDeckXrProtocol.claimBytes));
    expect(_tokenAt(received[0]), _token);
    expect(_tokenAt(received[1]), _token);

    // The encoder's buffers stay zero: the transport owns the stamp.
    expect(_tokenAt(input), 0);
    expect(_tokenAt(claim), 0);
  });

  test('close is idempotent and rejects later sends', () async {
    final receiver = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(receiver.close);
    final transport = await DroidDeckXrUdpTransport.connect(
      token: _token,
      port: receiver.port,
    );

    await transport.close();
    await transport.close();

    expect(transport.trySend(_packet()), isFalse);
    await expectLater(
      transport.send(_packet()),
      throwsA(
        isA<DroidDeckXrTransportException>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        ),
      ),
    );
  });

  test(
    'a datagram after the listener closes reports a UDP pairing failure',
    () async {
      final receiver = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = receiver.port;
      receiver.close();
      final transport = await DroidDeckXrUdpTransport.connect(
        token: _token,
        port: port,
      );
      addTearDown(transport.close);

      // The first datagram is sent; the ICMP port-unreachable arrives after it,
      // so the next send is the one that fails.
      await transport.send(_packet());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await expectLater(
        transport.send(_packet()),
        throwsA(
          isA<DroidDeckXrTransportException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('UDP pairing failed'),
              contains('offset 32'),
              contains('docs/GAMEPAD.md:128'),
            ),
          ),
        ),
      );
    },
  );

  test(
    'no token: one error names the socket and the untaken UDP fallback',
    () async {
      var udpCalls = 0;
      await expectLater(
        openDroidDeckXrTransport(
          connectUnix: () async =>
              throw const DroidDeckXrTransportException('no socket'),
          connectUdp: (_) async {
            udpCalls++;
            return FakeTransport();
          },
        ),
        throwsA(
          isA<DroidDeckXrTransportException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('droiddeck-ext-xr'),
              contains('UDP fallback'),
              contains('no pairing token'),
            ),
          ),
        ),
      );
      expect(udpCalls, 0);
    },
  );

  for (final token in <int?>[null, _token]) {
    test(
      'a working socket wins and leaves offset 32 zero (token: $token)',
      () async {
        var udpCalls = 0;
        final unix = FakeTransport();
        final transport = await openDroidDeckXrTransport(
          token: token,
          connectUnix: () async => unix,
          connectUdp: (_) async {
            udpCalls++;
            return FakeTransport();
          },
        );

        await transport.send(_input());
        await transport.send(_claim());

        expect(udpCalls, 0, reason: 'the UDP fallback was never opened');
        expect(unix.sent, hasLength(2));
        expect(_tokenAt(unix.sent[0]), 0);
        expect(_tokenAt(unix.sent[1]), 0);
      },
    );
  }

  test('a failed socket with a token opens UDP and stamps the claim', () async {
    final receiver = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(receiver.close);
    var openedWith = -1;
    final transport = await openDroidDeckXrTransport(
      token: _token,
      connectUnix: () async =>
          throw const DroidDeckXrTransportException('no socket'),
      connectUdp: (value) {
        openedWith = value;
        return DroidDeckXrUdpTransport.connect(
          token: value,
          port: receiver.port,
        );
      },
    );

    final claim = _claim();
    final datagrams = _receive(receiver, 1);
    await transport.send(claim);

    expect(openedWith, _token);
    expect(_tokenAt((await datagrams).single), _token);
    expect(_tokenAt(claim), 0);
  });

  test('both transports failing produces one error naming both', () async {
    await expectLater(
      openDroidDeckXrTransport(
        token: _token,
        connectUnix: () async =>
            throw const DroidDeckXrTransportException('no socket'),
        connectUdp: (_) async =>
            throw const DroidDeckXrTransportException('no datagram'),
      ),
      throwsA(
        isA<DroidDeckXrTransportException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('droiddeck-ext-xr'),
            contains('127.0.0.1:29842'),
            contains('no socket'),
            contains('no datagram'),
          ),
        ),
      ),
    );
  });

  test('a refused UDP write returns false and a reopen rebuilds UDP', () async {
    var unixCalls = 0;
    final tokens = <int>[];
    final first = FakeTransport(accept: false);
    final second = FakeTransport();
    final transport = await openDroidDeckXrTransport(
      token: _token,
      connectUnix: () async {
        unixCalls++;
        throw const DroidDeckXrTransportException('no socket');
      },
      connectUdp: (value) async {
        tokens.add(value);
        return tokens.length == 1 ? first : second;
      },
    );

    await transport.send(_packet(fill: 1));
    expect((transport as DroidDeckXrQueuedTransport).queuedPackets, 1);
    expect(second.sent, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 550));
    await transport.send(_packet(fill: 2));

    expect(unixCalls, 1, reason: 'reopen stays on UDP');
    expect(tokens, [_token, _token], reason: 'reopen keeps the token');
    expect(first.closed, isTrue);
    expect(second.sent, hasLength(2));
    expect(transport.queuedPackets, 0);
  });
}
