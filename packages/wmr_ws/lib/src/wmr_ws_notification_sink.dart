import 'dart:async';
import 'dart:collection';

import 'package:wmr_core/ble/ble_transport.dart';

/// A single-consumer notification queue with the daemon's drop policy.
///
/// The daemon drops the *newest* message when a client queue is full (512 by
/// default). The client does the same so a slow UI cannot make the Dart heap
/// grow without bound, and [dropped] makes the loss visible instead of
/// pretending the stream kept up.
///
/// Every notification goes through the bounded queue. Delivery is paced one
/// event at a time, so the stream controller's own buffer cannot grow either
/// when the consumer is slow but not paused. A paused subscription also keeps
/// filling the queue and overflows at the same bound. Notifications keep their
/// [BleNotification.receivedAtUs] stamp from the socket, so a message that
/// waited in this queue does not look newer than it is.
class WmrWsNotificationSink {
  WmrWsNotificationSink({this.capacity = 512})
    : assert(capacity > 0, 'capacity must be positive');

  final int capacity;

  final ListQueue<BleNotification> _queue = ListQueue<BleNotification>();
  late final StreamController<BleNotification> _controller =
      StreamController<BleNotification>(
        onListen: _schedule,
        onPause: () => _paused = true,
        onResume: () {
          _paused = false;
          _schedule();
        },
        onCancel: () {
          _paused = false;
          _queue.clear();
        },
      );

  bool _paused = false;
  bool _closed = false;
  bool _scheduled = false;
  int _dropped = 0;

  /// Notifications discarded because [capacity] was already queued.
  int get dropped => _dropped;

  bool get isClosed => _closed;

  /// Whether the single consumer is currently attached.
  bool get hasListeners => _controller.hasListener;

  Stream<BleNotification> get stream => _controller.stream;

  /// Queues [notification], or drops it when the queue is full.
  ///
  /// Returns false when it was dropped.
  bool add(BleNotification notification) {
    if (_closed) return false;
    if (_queue.length >= capacity) {
      _dropped++;
      return false;
    }
    _queue.add(notification);
    _schedule();
    return true;
  }

  /// Delivers an error to the consumer. Errors are never dropped: they are
  /// how a refused stream reaches `ControllerService.onError`.
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _controller.addError(error, stackTrace);
  }

  void _schedule() {
    if (_scheduled ||
        _paused ||
        _closed ||
        _queue.isEmpty ||
        !_controller.hasListener) {
      return;
    }
    _scheduled = true;
    // A timer, not a microtask: it yields to socket reads, so a burst cannot
    // be transferred into the stream controller's internal buffer in one go.
    Timer.run(_deliverOne);
  }

  void _deliverOne() {
    _scheduled = false;
    if (_paused || _closed || _queue.isEmpty || !_controller.hasListener) {
      return;
    }
    _controller.add(_queue.removeFirst());
    _schedule();
  }

  /// Closes the stream. Never awaited: a paused consumer would otherwise
  /// block `unsubscribe`.
  void close() {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    unawaited(_controller.close());
  }
}
