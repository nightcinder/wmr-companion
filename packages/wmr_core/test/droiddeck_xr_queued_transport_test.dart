import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/services/droiddeck_xr_queued_transport.dart';
import 'package:wmr_core/services/droiddeck_xr_transport.dart';

const _ms = 1000;

Uint8List _packet(int n) => Uint8List.fromList([n]);

class FakeNonBlockingTransport implements DroidDeckXrNonBlockingTransport {
  FakeNonBlockingTransport({this.accept = true});

  bool accept;
  bool closed = false;
  final List<int> sent = [];

  @override
  bool trySend(Uint8List packet) {
    if (closed || !accept) return false;
    sent.add(packet.first);
    return true;
  }

  @override
  Future<void> send(Uint8List packet) async =>
      throw UnsupportedError('the wrapper only calls trySend');

  @override
  Future<void> close() async => closed = true;
}

class Harness {
  Harness({
    FakeNonBlockingTransport? first,
    this.reopenFails = false,
    this.reopenAccepts = true,
  }) : first = first ?? FakeNonBlockingTransport();

  final FakeNonBlockingTransport first;
  final bool reopenFails;
  final bool reopenAccepts;
  final List<FakeNonBlockingTransport> reopened = [];
  int nowUsValue = 0;
  bool _failedOnce = false;

  late final DroidDeckXrQueuedTransport wrapper = DroidDeckXrQueuedTransport(
    transport: first,
    nowUs: () => nowUsValue,
    reopen: () async {
      if (reopenFails && !_failedOnce) {
        _failedOnce = true;
        throw const DroidDeckXrTransportException('cannot reopen');
      }
      final next = FakeNonBlockingTransport(accept: reopenAccepts);
      reopened.add(next);
      return next;
    },
  );

  void advanceMs(int ms) => nowUsValue += ms * _ms;
}

void main() {
  test('delivers packets in order while the socket accepts them', () async {
    final h = Harness();
    for (var i = 1; i <= 3; i++) {
      await h.wrapper.send(_packet(i));
    }
    expect(h.first.sent, [1, 2, 3]);
    expect(h.wrapper.queuedPackets, 0);
    expect(h.wrapper.droppedPackets, 0);
  });

  test('packet stats snapshot counts accepted, dropped and queued', () async {
    final h = Harness(first: FakeNonBlockingTransport(accept: false));
    await h.wrapper.send(_packet(1));
    await h.wrapper.send(_packet(2));
    expect(h.wrapper.packetStats.accepted, 0);
    expect(h.wrapper.packetStats.dropped, 0);
    expect(h.wrapper.packetStats.queued, 2);

    h.first.accept = true;
    await h.wrapper.send(_packet(3));
    expect(h.wrapper.packetStats.accepted, 3);
    expect(h.wrapper.packetStats.dropped, 0);
    expect(h.wrapper.packetStats.queued, 0);

    h.first.accept = false;
    for (var i = 0; i < 6; i++) {
      await h.wrapper.send(_packet(10 + i));
    }
    expect(h.wrapper.packetStats.queued, 4);
    expect(h.wrapper.packetStats.dropped, 2);
  });

  test('a full queue drops the oldest packet, keeping the newest', () async {
    final h = Harness(first: FakeNonBlockingTransport(accept: false));
    for (var i = 1; i <= 6; i++) {
      await h.wrapper.send(_packet(i));
    }
    expect(h.wrapper.queuedPackets, 4);
    expect(h.wrapper.droppedPackets, 2);

    h.first.accept = true;
    await h.wrapper.send(_packet(7));
    expect(h.first.sent, [4, 5, 6, 7]);
    expect(h.wrapper.droppedPackets, 3);
    expect(h.wrapper.queuedPackets, 0);
  });

  test('send never blocks: a refused write returns at once', () async {
    final h = Harness(first: FakeNonBlockingTransport(accept: false));
    await h.wrapper.send(_packet(1));
    expect(h.first.sent, isEmpty);
    expect(h.reopened, isEmpty);
  });

  test('does not reopen before 500 ms of continuous failure', () async {
    final h = Harness(first: FakeNonBlockingTransport(accept: false));
    await h.wrapper.send(_packet(1));
    h.advanceMs(499);
    await h.wrapper.send(_packet(2));
    expect(h.reopened, isEmpty);
    expect(h.first.closed, isFalse);
  });

  test('reopens at 500 ms and flushes the queue to the new socket', () async {
    final h = Harness(first: FakeNonBlockingTransport(accept: false));
    await h.wrapper.send(_packet(1));
    await h.wrapper.send(_packet(2));
    h.advanceMs(500);
    await h.wrapper.send(_packet(3));

    expect(h.first.closed, isTrue);
    expect(h.reopened, hasLength(1));
    expect(h.reopened.single.sent, [1, 2, 3]);
    expect(h.wrapper.queuedPackets, 0);
  });

  test('a successful write resets the failure window', () async {
    final h = Harness(first: FakeNonBlockingTransport(accept: false));
    await h.wrapper.send(_packet(1));
    h.advanceMs(400);
    h.first.accept = true;
    await h.wrapper.send(_packet(2));
    expect(h.first.sent, [1, 2]);

    h.first.accept = false;
    await h.wrapper.send(_packet(3));
    h.advanceMs(400);
    await h.wrapper.send(_packet(4));
    expect(h.reopened, isEmpty);
  });

  test('gives up after five reopens and throws on the next window', () async {
    final refusing = Harness(
      first: FakeNonBlockingTransport(accept: false),
      reopenAccepts: false,
    );
    await refusing.wrapper.send(_packet(1));
    for (var i = 0; i < 5; i++) {
      refusing.advanceMs(500);
      await refusing.wrapper.send(_packet(2 + i));
    }
    expect(refusing.reopened, hasLength(5));

    refusing.advanceMs(500);
    await expectLater(
      refusing.wrapper.send(_packet(9)),
      throwsA(isA<DroidDeckXrTransportException>()),
    );
    await expectLater(
      refusing.wrapper.send(_packet(10)),
      throwsA(isA<DroidDeckXrTransportException>()),
    );
  });

  test('a failed reopen is retried after another window, not thrown', () async {
    final h = Harness(
      first: FakeNonBlockingTransport(accept: false),
      reopenFails: true,
    );
    await h.wrapper.send(_packet(1));
    h.advanceMs(500);
    await h.wrapper.send(_packet(2));
    expect(h.reopened, isEmpty);
    expect(h.wrapper.queuedPackets, 2);

    h.advanceMs(500);
    await h.wrapper.send(_packet(3));
    expect(h.reopened, hasLength(1));
    expect(h.reopened.single.sent, [1, 2, 3]);
  });

  test('close closes the socket, drops the queue and rejects sends', () async {
    final h = Harness(first: FakeNonBlockingTransport(accept: false));
    await h.wrapper.send(_packet(1));
    await h.wrapper.close();
    expect(h.first.closed, isTrue);
    expect(h.wrapper.queuedPackets, 0);
    await expectLater(
      h.wrapper.send(_packet(2)),
      throwsA(isA<DroidDeckXrTransportException>()),
    );
  });

  test('overlapping flushes during a reconnect open one socket', () async {
    final gate = _GatedReopen();
    var now = 0;
    final first = FakeNonBlockingTransport(accept: false);
    final wrapper = DroidDeckXrQueuedTransport(
      transport: first,
      reopen: gate.call,
      nowUs: () => now,
    );

    await wrapper.send(_packet(1));
    now = 500 * _ms;
    final s2 = wrapper.send(_packet(2)); // reconnect #1 starts and waits
    await _settle();
    expect(gate.pending, hasLength(1));

    now = 1000 * _ms; // the failure window allows another reopen
    final s3 = wrapper.send(_packet(3)); // overlapping flush
    await _settle();
    expect(gate.pending, hasLength(1), reason: 'no second reconnect');

    gate.complete(0);
    await Future.wait([s2, s3]);
    expect(gate.opened, hasLength(1));
    expect(gate.opened.single.closed, isFalse);
    expect(gate.opened.single.sent, [1, 2, 3]);
    expect(first.closed, isTrue);
    expect(wrapper.queuedPackets, 0);
  });

  test(
    'close during a reconnect closes the new socket and installs nothing',
    () async {
      final gate = _GatedReopen();
      var now = 0;
      final first = FakeNonBlockingTransport(accept: false);
      final wrapper = DroidDeckXrQueuedTransport(
        transport: first,
        reopen: gate.call,
        nowUs: () => now,
      );

      await wrapper.send(_packet(1));
      now = 500 * _ms;
      final s2 = wrapper.send(_packet(2)); // reconnect in flight
      await _settle();
      expect(gate.pending, hasLength(1));

      final closing = wrapper.close();
      gate.complete(0);
      await closing;
      await s2;

      expect(gate.opened, hasLength(1));
      expect(gate.opened.single.closed, isTrue, reason: 'new socket closed');
      expect(gate.opened.single.sent, isEmpty, reason: 'nothing installed');
      expect(wrapper.queuedPackets, 0);
      await expectLater(
        wrapper.send(_packet(3)),
        throwsA(isA<DroidDeckXrTransportException>()),
      );
      expect(gate.pending, hasLength(1), reason: 'no reopen after close');
    },
  );
}

/// Reopen that stays pending until the test completes it.
class _GatedReopen {
  final List<Completer<DroidDeckXrNonBlockingTransport>> pending = [];
  final List<FakeNonBlockingTransport> opened = [];

  Future<DroidDeckXrNonBlockingTransport> call() {
    final completer = Completer<DroidDeckXrNonBlockingTransport>();
    pending.add(completer);
    return completer.future;
  }

  void complete(int index) {
    final fake = FakeNonBlockingTransport();
    opened.add(fake);
    pending[index].complete(fake);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
