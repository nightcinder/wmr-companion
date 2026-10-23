// Port of WMR_Bridge tests/test_protocol.c (reassembler and encoder parts).
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart' show syntheticFrame;
import 'package:wmr_core/protocol/wmr_fragment.dart';

/// Pushes every fragment of [f] and returns the last result and the count.
(ReassemblyResult, int) sendFrame(WmrReassembler r, WmrFrame f, int capacity) {
  final fragments = encodeFrame(f, capacity);
  var result = ReassemblyResult.partial;
  for (final p in fragments) {
    result = r.push(p);
  }
  return (result, fragments.length);
}

Uint8List frag(WmrFrame f, int offset, int capacity) =>
    encodeFragment(f, offset, capacity)!;

void main() {
  test('capacity', () {
    expect(notificationCapacity(23), 20);
    expect(notificationCapacity(15), 0);
    expect(notificationCapacity(16), 13);
    expect(notificationCapacity(247), 244);
    expect(notificationCapacity(517), 244);
    expect(notificationCapacity(0), 0);
  });

  test('golden packet', () {
    final f = syntheticFrame(wmrHandRight, 0x01020304);
    final first = frag(f, 0, 44);
    expect(first.length, 44);
    expect(first.sublist(0, 12), [
      0x52,
      0x01,
      0x04,
      0x03,
      0x02,
      0x01,
      0x2E,
      0x00,
      0x00,
      0x00,
      0x20,
      0x00,
    ]);
    expect(first.sublist(12), f.data.sublist(0, 32));

    final second = frag(f, 32, 44);
    expect(second.length, 26);
    expect(second.sublist(0, 12), [
      0x52,
      0x01,
      0x04,
      0x03,
      0x02,
      0x01,
      0x2E,
      0x00,
      0x20,
      0x00,
      0x0E,
      0x00,
    ]);
    expect(second.sublist(12), f.data.sublist(32));
  });

  test('encoder argument checks', () {
    final f = syntheticFrame(0, 1);
    expect(encodeFragment(f, 0, 12), isNull);
    expect(encodeFragment(f, 46, 44), isNull);
    expect(encodeFragment(f, 100, 44), isNull);
  });

  test('round trip, every capacity from 13 to 244, both hands', () {
    for (var capacity = 13; capacity <= 244; capacity++) {
      for (var hand = 0; hand < wmrNumControllers; hand++) {
        final r = WmrReassembler();
        final f = syntheticFrame(hand, 1000 + capacity);
        final (result, count) = sendFrame(r, f, capacity);
        final perFragment = capacity - 12;
        expect(result, ReassemblyResult.frameComplete);
        expect(r.lastFrame, f);
        expect(count, (46 + perFragment - 1) ~/ perFragment);
        expect(r.framesIncomplete[hand], 0);
        expect(r.errors, 0);
      }
    }
  });

  test('whole frame in one fragment', () {
    final r = WmrReassembler();
    final f = syntheticFrame(wmrHandLeft, 7);
    final (result, count) = sendFrame(r, f, 244);
    expect(result, ReassemblyResult.frameComplete);
    expect(count, 1);
    expect(r.lastFrame, f);
  });

  test('many fragmented frames, both hands, back to back', () {
    final r = WmrReassembler();
    for (var seq = 1; seq <= 100; seq++) {
      for (var hand = 0; hand < 2; hand++) {
        final f = syntheticFrame(hand, seq);
        expect(sendFrame(r, f, 20).$1, ReassemblyResult.frameComplete);
        expect(r.lastFrame, f);
      }
    }
    expect(r.framesComplete, [100, 100]);
    expect(r.framesIncomplete, [0, 0]);
    expect(r.errors, 0);
  });

  test('fragments of the two hands interleaved', () {
    final r = WmrReassembler();
    final l = syntheticFrame(0, 5);
    final rt = syntheticFrame(1, 9);
    expect(r.push(frag(l, 0, 44)), ReassemblyResult.partial);
    expect(r.push(frag(rt, 0, 44)), ReassemblyResult.partial);
    expect(r.push(frag(l, 32, 44)), ReassemblyResult.frameComplete);
    expect(r.lastFrame, l);
    expect(r.push(frag(rt, 32, 44)), ReassemblyResult.frameComplete);
    expect(r.lastFrame, rt);
    expect(r.framesIncomplete, [0, 0]);
  });

  test('incomplete frame is abandoned when the next frame starts', () {
    final r = WmrReassembler();
    final a = syntheticFrame(0, 1);
    final b = syntheticFrame(0, 2);
    expect(r.push(frag(a, 0, 44)), ReassemblyResult.partial);
    expect(sendFrame(r, b, 44).$1, ReassemblyResult.frameComplete);
    expect(r.lastFrame, b);
    expect(r.framesIncomplete[0], 1);
    expect(r.framesComplete[0], 1);
    expect(r.errors, 0);
  });

  test('continuation fragment with no frame in progress', () {
    final r = WmrReassembler();
    final a = syntheticFrame(1, 3);
    expect(r.push(frag(a, 32, 44)), ReassemblyResult.errOutOfOrder);
    expect(r.framesComplete[1], 0);
    expect(r.errors, 1);
  });

  test('lost middle fragment: frame never completes', () {
    final r = WmrReassembler();
    final a = syntheticFrame(0, 4);
    expect(r.push(frag(a, 0, 24)), ReassemblyResult.partial);
    expect(r.push(frag(a, 24, 24)), ReassemblyResult.errOutOfOrder);
    expect(r.framesIncomplete[0], 1);
    expect(r.framesComplete[0], 0);
    expect(r.push(frag(a, 36, 24)), ReassemblyResult.errOutOfOrder);
    expect(r.framesComplete[0], 0);
  });

  test('continuation with a different sequence number', () {
    final r = WmrReassembler();
    expect(
      r.push(frag(syntheticFrame(0, 10), 0, 44)),
      ReassemblyResult.partial,
    );
    expect(
      r.push(frag(syntheticFrame(0, 11), 32, 44)),
      ReassemblyResult.errOutOfOrder,
    );
    expect(r.framesIncomplete[0], 1);
    expect(r.framesComplete[0], 0);
  });

  test('duplicate continuation fragment', () {
    final r = WmrReassembler();
    final a = syntheticFrame(0, 12);
    final p1 = frag(a, 12, 24);
    expect(r.push(frag(a, 0, 24)), ReassemblyResult.partial);
    expect(r.push(p1), ReassemblyResult.partial);
    expect(r.push(p1), ReassemblyResult.errOutOfOrder);
    expect(r.framesComplete[0], 0);
    expect(r.framesIncomplete[0], 1);
  });

  test('malformed packets', () {
    final r = WmrReassembler();
    final f = syntheticFrame(0, 1);
    final good = frag(f, 0, 244);
    Uint8List bad(void Function(Uint8List b) mutate) =>
        Uint8List.fromList(good)..apply(mutate);

    expect(r.push(good.sublist(0, 11)), ReassemblyResult.errShort);
    expect(r.push(Uint8List(0)), ReassemblyResult.errShort);
    expect(r.push(bad((b) => b[0] = 0x51)), ReassemblyResult.errMagic);
    expect(r.push(bad((b) => b[1] = 2)), ReassemblyResult.errHand);
    expect(
      r.push(good.sublist(0, good.length - 1)),
      ReassemblyResult.errLength,
    );
    expect(r.push(bad((b) => b[6] = b[7] = 0)), ReassemblyResult.errLength);
    expect(
      r.push(bad((b) => b[6] = wmrMaxFrame + 1)),
      ReassemblyResult.errLength,
    );
    expect(r.push(bad((b) => b[8] = 5)), ReassemblyResult.errLength);
    final zeroChunk = Uint8List.fromList(good.sublist(0, 12))
      ..[10] = 0
      ..[11] = 0;
    expect(r.push(zeroChunk), ReassemblyResult.errLength);

    expect(r.framesComplete[0], 0);
    expect(r.push(good), ReassemblyResult.frameComplete);
    expect(r.lastFrame, f);
  });

  test('malformed fragment abandons the partial frame', () {
    final r = WmrReassembler();
    final a = syntheticFrame(0, 20);
    expect(r.push(frag(a, 0, 44)), ReassemblyResult.partial);
    final p1 = frag(a, 32, 44)..[10] = 3;
    expect(r.push(p1), ReassemblyResult.errLength);
    expect(r.framesIncomplete[0], 1);
  });

  test('captured sample frames round trip at every capacity', () {
    final lines = File('test/fixtures/controller_frames.txt')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty && !l.startsWith('#'));
    var samples = 0;
    for (final line in lines) {
      final bytes = line.trim().split(RegExp(r'\s+')).skip(1);
      final f = WmrFrame(
        hand: samples & 1,
        sequence: 100 + samples,
        data: Uint8List.fromList([
          for (final b in bytes) int.parse(b, radix: 16),
        ]),
      );
      expect(f.length, 46);
      expect(f.data[0], 0xA1);
      for (var capacity = 13; capacity <= 244; capacity++) {
        final r = WmrReassembler();
        expect(sendFrame(r, f, capacity).$1, ReassemblyResult.frameComplete);
        expect(r.lastFrame, f);
      }
      samples++;
    }
    expect(samples, greaterThanOrEqualTo(2));
  });

  test('sequenceDelta wraps modulo 2^32', () {
    expect(sequenceDelta(5, 6), 1);
    expect(sequenceDelta(0xffffffff, 0), 1);
    expect(sequenceDelta(0xfffffffe, 3), 5);
    expect(sequenceDelta(10, 10), 0);
    expect(sequenceDelta(10, 9), -1);
  });
}

extension on Uint8List {
  void apply(void Function(Uint8List b) f) => f(this);
}
