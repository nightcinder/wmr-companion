/// Wire format of the bridge's FF11 notifications.
///
/// Mirrors WMR_Bridge `src/wmr_protocol.c` (encoder and reference
/// reassembler). See docs/PROTOCOL.md.
library;

import 'dart:typed_data';

const int wmrNumControllers = 2;
const int wmrHandLeft = 0;
const int wmrHandRight = 1;

const int wmrFragmentHeaderSize = 12;
const int wmrFragmentMagic = 0x52;
const int wmrMaxFrame = 64;
const int wmrMaxNotification = 244;
const int attNotifyOverhead = 3;

/// One controller HID input report: `0xA1`, report ID, payload (46 bytes
/// observed). Not decoded.
class WmrFrame {
  WmrFrame({required this.hand, required this.sequence, required this.data});

  final int hand;

  /// Per-hand u32 counter on the ESP32. Wraps; compare with [sequenceDelta].
  final int sequence;
  final Uint8List data;

  int get length => data.length;

  @override
  bool operator ==(Object other) {
    if (other is! WmrFrame ||
        other.hand != hand ||
        other.sequence != sequence ||
        other.length != length) {
      return false;
    }
    for (var i = 0; i < length; i++) {
      if (other.data[i] != data[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(hand, sequence, Object.hashAll(data));
}

/// `b - a` modulo 2^32, as a signed 32-bit value. 1 means consecutive.
int sequenceDelta(int a, int b) => ((b - a) & 0xffffffff).toSigned(32);

/// Largest notification value for a negotiated ATT MTU, or 0 if the MTU
/// cannot carry a payload byte.
int notificationCapacity(int attMtu) {
  if (attMtu <= wmrFragmentHeaderSize + attNotifyOverhead) return 0;
  final capacity = attMtu - attNotifyOverhead;
  return capacity > wmrMaxNotification ? wmrMaxNotification : capacity;
}

/// Encodes the fragment of [frame] starting at [offset]. Returns null on
/// invalid arguments, like the firmware's 0 return.
Uint8List? encodeFragment(WmrFrame frame, int offset, int capacity) {
  if (capacity <= wmrFragmentHeaderSize) return null;
  if (offset < 0 || offset >= frame.length) return null;
  var chunk = frame.length - offset;
  if (chunk > capacity - wmrFragmentHeaderSize) {
    chunk = capacity - wmrFragmentHeaderSize;
  }
  final out = Uint8List(wmrFragmentHeaderSize + chunk);
  ByteData.sublistView(out)
    ..setUint8(0, wmrFragmentMagic)
    ..setUint8(1, frame.hand)
    ..setUint32(2, frame.sequence, Endian.little)
    ..setUint16(6, frame.length, Endian.little)
    ..setUint16(8, offset, Endian.little)
    ..setUint16(10, chunk, Endian.little);
  out.setRange(wmrFragmentHeaderSize, out.length, frame.data, offset);
  return out;
}

/// Encodes a whole frame as the sequence of notifications the bridge sends
/// for [capacity].
List<Uint8List> encodeFrame(WmrFrame frame, int capacity) {
  final fragments = <Uint8List>[];
  var offset = 0;
  while (offset < frame.length) {
    final fragment = encodeFragment(frame, offset, capacity);
    if (fragment == null) break;
    fragments.add(fragment);
    offset += fragment.length - wmrFragmentHeaderSize;
  }
  return fragments;
}

enum ReassemblyResult {
  partial,
  frameComplete,
  errShort,
  errMagic,
  errHand,
  errLength,
  errOutOfOrder,
}

class _Slot {
  bool active = false;
  int sequence = 0;
  int total = 0;
  int received = 0;
  final Uint8List data = Uint8List(wmrMaxFrame);
}

/// Reassembles fragments into frames, one slot per hand. Same rules and
/// counters as `wmr_reassembler_push`.
class WmrReassembler {
  final List<_Slot> _slots = List.generate(wmrNumControllers, (_) => _Slot());

  final List<int> framesComplete = List.filled(wmrNumControllers, 0);

  /// Partial frames abandoned (new frame started, out of order, sequence
  /// changed mid-frame, or malformed fragment).
  final List<int> framesIncomplete = List.filled(wmrNumControllers, 0);

  /// Malformed or out-of-order fragments.
  int errors = 0;

  /// The frame completed by the last [push] that returned
  /// [ReassemblyResult.frameComplete].
  WmrFrame? lastFrame;

  void _abandon(int hand) {
    final s = _slots[hand];
    if (s.active) {
      framesIncomplete[hand]++;
      s.active = false;
    }
  }

  ReassemblyResult push(Uint8List packet) {
    final size = packet.length;
    if (size < wmrFragmentHeaderSize) {
      errors++;
      return ReassemblyResult.errShort;
    }
    if (packet[0] != wmrFragmentMagic) {
      errors++;
      return ReassemblyResult.errMagic;
    }
    final hand = packet[1];
    if (hand >= wmrNumControllers) {
      errors++;
      return ReassemblyResult.errHand;
    }

    final bytes = ByteData.sublistView(packet);
    final sequence = bytes.getUint32(2, Endian.little);
    final total = bytes.getUint16(6, Endian.little);
    final offset = bytes.getUint16(8, Endian.little);
    final chunk = bytes.getUint16(10, Endian.little);

    if (chunk != size - wmrFragmentHeaderSize ||
        chunk == 0 ||
        total == 0 ||
        total > wmrMaxFrame ||
        offset >= total ||
        chunk > total - offset) {
      _abandon(hand);
      errors++;
      return ReassemblyResult.errLength;
    }

    final s = _slots[hand];
    if (offset == 0) {
      _abandon(hand);
      s
        ..active = true
        ..sequence = sequence
        ..total = total
        ..received = 0;
    } else if (!s.active ||
        s.sequence != sequence ||
        s.total != total ||
        s.received != offset) {
      _abandon(hand);
      errors++;
      return ReassemblyResult.errOutOfOrder;
    }

    s.data.setRange(offset, offset + chunk, packet, wmrFragmentHeaderSize);
    s.received = offset + chunk;
    if (s.received < s.total) return ReassemblyResult.partial;

    s.active = false;
    framesComplete[hand]++;
    lastFrame = WmrFrame(
      hand: hand,
      sequence: s.sequence,
      data: Uint8List.fromList(s.data.sublist(0, s.total)),
    );
    return ReassemblyResult.frameComplete;
  }
}
