import 'dart:async';

import '../ble/ble_transport.dart';
import '../protocol/gatt.dart';
import '../protocol/wmr_fragment.dart';

/// A reassembled frame with the phone-side receive time of its last fragment.
class ReceivedFrame {
  const ReceivedFrame(this.frame, this.receivedAtUs);

  final WmrFrame frame;
  final int receivedAtUs;
}

/// Per-hand stream counters. Gaps come from the ESP32 sequence numbers only.
class HandStats {
  const HandStats({
    this.frames = 0,
    this.incomplete = 0,
    this.lastSequence,
    this.gaps = 0,
    this.outOfOrder = 0,
  });

  final int frames;
  final int incomplete;
  final int? lastSequence;

  /// Frames missing between consecutive received sequence numbers.
  final int gaps;

  /// Received sequence numbers not greater than the previous one (duplicates,
  /// reordering, or an ESP32 reboot).
  final int outOfOrder;
}

class StreamStats {
  const StreamStats({required this.hands, this.errors = 0});

  final List<HandStats> hands;
  final int errors;
}

/// Subscribes to the bridge stream and reassembles frames.
class ControllerService {
  ControllerService(this.transport, this.deviceId);

  final BleTransport transport;
  final String deviceId;

  final WmrReassembler _reassembler = WmrReassembler();
  final List<int?> _lastSeq = List.filled(wmrNumControllers, null);
  final List<int> _gaps = List.filled(wmrNumControllers, 0);
  final List<int> _outOfOrder = List.filled(wmrNumControllers, 0);
  final StreamController<ReceivedFrame> _frames = StreamController.broadcast();
  StreamSubscription<BleNotification>? _subscription;

  Stream<ReceivedFrame> get frames => _frames.stream;

  /// Connects and subscribes. Call again after every reconnect: the bridge
  /// forgets the subscription on disconnect.
  Future<void> start() async {
    await transport.connect(deviceId);
    await _subscription?.cancel();
    _subscription = transport
        .subscribe(deviceId, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid)
        .listen(_onNotification);
  }

  void _onNotification(BleNotification n) {
    if (_reassembler.push(n.value) != ReassemblyResult.frameComplete) return;
    final frame = _reassembler.lastFrame!;
    final hand = frame.hand;
    final last = _lastSeq[hand];
    if (last != null) {
      final delta = sequenceDelta(last, frame.sequence);
      if (delta > 1) {
        _gaps[hand] += delta - 1;
      } else if (delta <= 0) {
        _outOfOrder[hand]++;
      }
    }
    _lastSeq[hand] = frame.sequence;
    _frames.add(ReceivedFrame(frame, n.receivedAtUs));
  }

  StreamStats get stats => StreamStats(
    hands: [
      for (var h = 0; h < wmrNumControllers; h++)
        HandStats(
          frames: _reassembler.framesComplete[h],
          incomplete: _reassembler.framesIncomplete[h],
          lastSequence: _lastSeq[h],
          gaps: _gaps[h],
          outOfOrder: _outOfOrder[h],
        ),
    ],
    errors: _reassembler.errors,
  );

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _frames.close();
  }
}
