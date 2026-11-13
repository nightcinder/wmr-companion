import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'imu_log_recorder.dart';

/// Writes chunks to a file through an [IOSink].
///
/// A flush is started after 64 KiB is written since the last flush, or 250 ms
/// after the first unflushed chunk (a one-shot timer), whichever comes first.
/// Writes are refused, and the chunk is dropped, while more than
/// [maxOutstandingBytes] are not yet flushed. The first I/O error is kept in
/// [error] and every later chunk is refused.
class ImuLogFileSink implements ImuLogSink {
  ImuLogFileSink(
    File file, {
    this.flushBytes = 64 * 1024,
    this.flushDelay = const Duration(milliseconds: 250),
    this.maxOutstandingBytes = 4 * 1024 * 1024,
  }) : _sink = file.openWrite();

  final IOSink _sink;
  final int flushBytes;
  final Duration flushDelay;
  final int maxOutstandingBytes;

  /// Accepted bytes not yet confirmed flushed.
  int _outstanding = 0;

  /// Accepted bytes not yet claimed by a flush. Each flush claims these
  /// once, so the flushes together subtract exactly what was accepted.
  int _unclaimed = 0;
  int _sinceFlush = 0;
  Timer? _timer;
  Object? _error;
  bool _closed = false;

  /// Flushes run one after another, so each completes in order.
  Future<void> _flushChain = Future<void>.value();

  /// The first write or flush error, or null.
  Object? get error => _error;

  /// Bytes accepted but not yet confirmed flushed.
  int get outstandingBytes => _outstanding;

  @override
  bool add(Uint8List chunk) {
    if (_closed || _error != null) return false;
    if (_outstanding + chunk.length > maxOutstandingBytes) return false;
    try {
      _sink.add(chunk);
    } on Object catch (e) {
      _error = e;
      return false;
    }
    _outstanding += chunk.length;
    _unclaimed += chunk.length;
    _sinceFlush += chunk.length;
    if (_sinceFlush >= flushBytes) {
      _flushNow();
    } else {
      _timer ??= Timer(flushDelay, _flushNow);
    }
    return true;
  }

  void _flushNow() {
    _timer?.cancel();
    _timer = null;
    _sinceFlush = 0;
    final claimed = _unclaimed;
    _unclaimed = 0;
    _flushChain = _flushChain.then<void>((_) async {
      try {
        await _sink.flush();
        _outstanding -= claimed;
      } on Object catch (e) {
        _error ??= e;
      }
    });
  }

  /// Flushes everything, then closes the file.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _flushNow();
    await _flushChain;
    try {
      await _sink.close();
    } on Object catch (e) {
      _error ??= e;
    }
  }
}
