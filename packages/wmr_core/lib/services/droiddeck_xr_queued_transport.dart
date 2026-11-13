import 'dart:collection';
import 'dart:typed_data';

import '../domain/droiddeck_xr_sink.dart';
import 'droiddeck_xr_transport.dart' show DroidDeckXrTransportException;

/// A transport that can attempt one send without blocking.
///
/// [trySend] returns false when the packet was not written now (for example
/// the socket buffer is full or the write failed). It never waits.
abstract interface class DroidDeckXrNonBlockingTransport
    implements DroidDeckXrTransport {
  bool trySend(Uint8List packet);
}

int _defaultNowUs() => _clock.elapsedMicroseconds;
final Stopwatch _clock = Stopwatch()..start();

/// Keeps the pipeline loop from blocking on a slow DroidDeck host.
///
/// [send] queues the packet and tries to write the queue without blocking.
/// The queue holds at most [capacity] packets; when it is full the oldest
/// packet is dropped, so the host always gets the newest pose. If writes keep
/// failing for [reopenAfter] of continuous failure, the wrapper calls [reopen]
/// and continues with the new transport. It does this at most [maxReopens]
/// times in one failure episode. After that the failure is thrown from [send],
/// which is the same error path the sink already uses.
class DroidDeckXrQueuedTransport implements DroidDeckXrTransport {
  DroidDeckXrQueuedTransport({
    required DroidDeckXrNonBlockingTransport transport,
    required this.reopen,
    this.capacity = 4,
    this.reopenAfter = const Duration(milliseconds: 500),
    this.maxReopens = 5,
    this.nowUs = _defaultNowUs,
  }) : _transport = transport;

  /// Opens a replacement transport after a continuous failure.
  final Future<DroidDeckXrNonBlockingTransport> Function() reopen;
  final int capacity;
  final Duration reopenAfter;
  final int maxReopens;

  /// Monotonic clock in microseconds. Injected by tests.
  final int Function() nowUs;

  DroidDeckXrNonBlockingTransport _transport;
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  int _droppedPackets = 0;
  int? _failingSinceUs;
  int _reopensInEpisode = 0;
  bool _closed = false;

  /// Packets discarded because the queue was full.
  int get droppedPackets => _droppedPackets;

  /// Packets waiting for the socket to accept them.
  int get queuedPackets => _queue.length;

  @override
  Future<void> send(Uint8List packet) async {
    if (_closed) throw const DroidDeckXrTransportException('transport closed');
    if (_queue.length >= capacity) {
      _queue.removeFirst();
      _droppedPackets++;
    }
    _queue.addLast(packet);
    await _flush();
  }

  Future<void> _flush() async {
    while (_queue.isNotEmpty) {
      if (_transport.trySend(_queue.first)) {
        _queue.removeFirst();
        _failingSinceUs = null;
        _reopensInEpisode = 0;
        continue;
      }
      final now = nowUs();
      final since = _failingSinceUs ??= now;
      if (now - since < reopenAfter.inMicroseconds) return;
      if (_reopensInEpisode >= maxReopens) {
        await _giveUp();
        throw const DroidDeckXrTransportException(
          'DroidDeck ext-xr socket still failing after reopening',
        );
      }
      _reopensInEpisode++;
      _failingSinceUs = now;
      await _replaceTransport();
    }
  }

  Future<void> _replaceTransport() async {
    final old = _transport;
    try {
      await old.close();
    } on Object {
      // The old transport is already failing; closing it is best effort.
    }
    try {
      _transport = await reopen();
    } on DroidDeckXrTransportException {
      // The next attempt waits another reopenAfter, counted in this episode.
    }
  }

  Future<void> _giveUp() async {
    _closed = true;
    _queue.clear();
    try {
      await _transport.close();
    } on Object {
      // Already failing; the caller gets the exception below.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    await _transport.close();
  }
}
