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
///
/// Only one flush runs at a time. A send that arrives during a reconnect only
/// queues its packet; the flush in progress writes it afterwards. [close] is
/// final: a socket that finishes opening after [close] is closed at once and
/// never installed, and [close] completes only after that has happened.
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
  bool _flushing = false;
  Future<void>? _replacing;

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
    // One flush at a time. If one is already running (possibly waiting for a
    // reconnect), it drains this packet too, so there is nothing to do here.
    if (_flushing) return;
    _flushing = true;
    try {
      while (!_closed && _queue.isNotEmpty) {
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
    } finally {
      _flushing = false;
    }
  }

  /// Closes the failing socket and opens a replacement. [close] waits for it.
  Future<void> _replaceTransport() {
    final replacing = _swapTransport();
    _replacing = replacing;
    return replacing;
  }

  Future<void> _swapTransport() async {
    try {
      final old = _transport;
      try {
        await old.close();
      } on Object {
        // The old transport is already failing; closing it is best effort.
      }
      if (_closed) return;
      try {
        final next = await reopen();
        if (_closed) {
          // close() ran while this socket was opening. Own it here and close
          // it; nothing is installed after close.
          await _closeQuietly(next);
        } else {
          _transport = next;
        }
      } on DroidDeckXrTransportException {
        // The next attempt waits another reopenAfter, counted in this episode.
      }
    } finally {
      // Cleared in the same synchronous step that installed (or dropped) the
      // new transport, so close() never sees a finished swap as in flight.
      _replacing = null;
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
    if (!_closed) {
      _closed = true;
      _queue.clear();
      // While a replacement is in flight it owns the socket it is opening, and
      // the old socket is already closed. Closing _transport here would race it.
      if (_replacing == null) await _transport.close();
    }
    final replacing = _replacing;
    if (replacing != null) {
      try {
        await replacing;
      } on Object {
        // The replacement reports its own failure to the flush, not to close.
      }
    }
  }

  Future<void> _closeQuietly(DroidDeckXrNonBlockingTransport transport) async {
    try {
      await transport.close();
    } on Object {
      // Best effort: the socket is being abandoned.
    }
  }
}
