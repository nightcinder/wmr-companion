import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_ws/src/wmr_ws_notification_sink.dart';

BleNotification frame(int value) => BleNotification(
  value: Uint8List.fromList([value]),
  receivedAtUs: 1000 + value,
);

void main() {
  test('a slow but unpaused consumer is still bounded by capacity', () async {
    final sink = WmrWsNotificationSink(capacity: 4);
    final received = <BleNotification>[];
    final sub = sink.stream.listen(received.add);
    addTearDown(sub.cancel);
    addTearDown(sink.close);

    // All ten arrive before the delivery timer can run, as a socket burst
    // would. The consumer is attached and not paused, so this used to bypass
    // the queue entirely.
    for (var i = 0; i < 10; i++) {
      sink.add(frame(i));
    }
    expect(sink.dropped, 6);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received.map((n) => n.value.single).toList(), [
      0,
      1,
      2,
      3,
    ], reason: 'oldest four are kept, the newest six are dropped');
    expect(received.map((n) => n.receivedAtUs).toList(), [
      1000,
      1001,
      1002,
      1003,
    ], reason: 'queueing must not change the arrival stamp');
  });

  test('a paused consumer queues up to capacity and then drops', () async {
    final sink = WmrWsNotificationSink(capacity: 2);
    final received = <BleNotification>[];
    final sub = sink.stream.listen(received.add);
    addTearDown(sub.cancel);
    addTearDown(sink.close);

    sub.pause();
    expect(sink.add(frame(1)), isTrue);
    expect(sink.add(frame(2)), isTrue);
    expect(sink.add(frame(3)), isFalse);
    expect(sink.dropped, 1);
    expect(received, isEmpty);

    sub.resume();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received.map((n) => n.value.single).toList(), [1, 2]);
  });

  test('errors are never dropped, even with a full queue', () async {
    final sink = WmrWsNotificationSink(capacity: 1);
    final errors = <Object>[];
    final sub = sink.stream.listen(
      (_) {},
      onError: (Object error) => errors.add(error),
    );
    addTearDown(sub.cancel);
    addTearDown(sink.close);

    sink.add(frame(1));
    sink.add(frame(2)); // dropped, queue is full
    sink.addError(StateError('refused'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(errors, hasLength(1));
  });
}
