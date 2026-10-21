import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/protocol/wmr_fragment.dart';
import 'package:wmr_companion/services/capture_files.dart';
import 'package:wmr_companion/services/capture_recorder.dart';
import 'package:wmr_companion/services/controller_service.dart';

ReceivedFrame rf(int hand, int seq, int us, {int length = 46}) =>
    ReceivedFrame(syntheticFrame(hand, seq, length: length), us);

CaptureRecorder newRecorder(CaptureSink sink, {int? mtu = 517}) =>
    CaptureRecorder(
      sink: sink,
      hand: wmrHandLeft,
      mtu: mtu,
      started: DateTime(2026, 10, 21, 9, 8, 7),
      originUs: 1000000,
    );

void main() {
  group('format', () {
    test('output matches the golden file in the desktop tool format', () {
      final sink = MemoryCaptureSink();
      final r = newRecorder(sink);
      r.addFrame(rf(0, 1, 1005000)); // before any phase: dropped
      r.beginPhase('still', 1000000);
      r.addFrame(rf(0, 8231, 1013251));
      r.addFrame(rf(1, 500, 1014000));
      r.addFrame(rf(0, 8232, 1018000));
      r.addFrame(rf(0, 8235, 1030000));
      r.endPhase(1100000);
      r.addFrame(rf(0, 8236, 1150000)); // between phases: dropped
      r.beginPhase('twist_cw', 1200000);
      r.addFrame(rf(0, 8236, 1205000));
      r.endPhase(1300000);

      final golden = File('test/fixtures/capture_golden.txt')
          .readAsStringSync();
      expect(sink.text, golden);
    });

    test('header carries hand and MTU, unknown MTU is spelled out', () {
      final text = CaptureFormat.header(
        hand: wmrHandRight,
        mtu: null,
        started: DateTime(2026, 1, 2, 3, 4, 5),
      );
      expect(
        text,
        '# wmr-capture v1\n'
        '# source: BLE FF11 raw stream via wmr_companion app (phone)\n'
        '# hand: RIGHT (as stated by the operator)\n'
        '# mtu: unknown\n'
        '# started: 2026-01-02T03:04:05\n',
      );
    });

    test('seconds use six decimals like %.6f', () {
      expect(formatCaptureSeconds(0), '0.000000');
      expect(formatCaptureSeconds(13251), '0.013251');
      expect(formatCaptureSeconds(12345678), '12.345678');
      expect(formatCaptureSeconds(-5), '0.000000');
    });

    test('file name is hand-YYYYMMDD-HHMMSS.txt', () {
      expect(
        CaptureFormat.fileName(wmrHandLeft, DateTime(2026, 10, 21, 9, 8, 7)),
        'left-20261021-090807.txt',
      );
      expect(
        CaptureFormat.fileName(wmrHandRight, DateTime(2026, 1, 2, 13, 14, 15)),
        'right-20260102-131415.txt',
      );
    });

    test('phase names and order match capture_ble.py', () {
      expect(capturePhases.map((p) => p.name), [
        'still',
        'twist_cw',
        'flip_away',
        'lean_right',
      ]);
    });

    test('frames that are not 46 bytes are skipped and counted', () {
      final sink = MemoryCaptureSink();
      final r = newRecorder(sink);
      r.beginPhase('still', 1000000);
      r.addFrame(rf(0, 1, 1001000, length: 20));
      r.addFrame(rf(0, 2, 1002000));
      final s = r.endPhase(1003000);
      expect(r.skippedFrames, 1);
      expect(s.hands[0].frames, 1);
      expect(
        sink.text.split('\n').where((l) => l.startsWith('F ')),
        hasLength(1),
      );
    });
  });

  group('summary', () {
    test('counts frames, gaps, missing and rates per hand', () {
      final r = newRecorder(MemoryCaptureSink());
      r.beginPhase('still', 1000000);
      r.addFrame(rf(0, 8231, 1013251));
      r.addFrame(rf(1, 500, 1014000));
      r.addFrame(rf(0, 8232, 1018000));
      r.addFrame(rf(0, 8235, 1030000));
      final s = r.endPhase(1100000);

      final left = s.hands[0];
      expect(left.frames, 3);
      expect(left.gapEvents, 1);
      expect(left.missing, 2);
      expect(left.lossFraction, closeTo(2 / 5, 1e-12));
      expect(left.effectiveHz, closeTo(2 / 0.016749, 1e-6));
      expect(left.producedHz, closeTo(4 / 0.016749, 1e-6));
      expect(s.hands[1].frames, 1);
      expect(s.hands[1].effectiveHz, 0);
      expect(s.lossy, isTrue);
      expect(
        left.line('LEFT'),
        'LEFT  frames=3 gaps=1 missing=2 (40.0% lost) '
        'effective=119.4 Hz produced=238.8 Hz',
      );
    });

    test('a clean run is not lossy and has the expected rate', () {
      final r = newRecorder(MemoryCaptureSink());
      r.beginPhase('still', 1000000);
      // 170 Hz for one second, both hands.
      for (var i = 0; i <= 170; i++) {
        final us = 1000000 + i * 1000000 ~/ 170;
        r.addFrame(rf(0, 100 + i, us));
        r.addFrame(rf(1, 900 + i, us));
      }
      final s = r.endPhase(2100000);
      for (final h in s.hands) {
        expect(h.frames, 171);
        expect(h.missing, 0);
        expect(h.effectiveHz, closeTo(170, 0.5));
      }
      expect(s.lossy, isFalse);
    });

    test('sequence wrap is not a gap; backwards and duplicates are '
        'out of order, not missing', () {
      final r = newRecorder(MemoryCaptureSink());
      r.beginPhase('still', 1000000);
      r.addFrame(rf(0, 0xfffffffe, 1001000));
      r.addFrame(rf(0, 0xffffffff, 1002000));
      r.addFrame(rf(0, 0, 1003000));
      r.addFrame(rf(0, 0, 1004000));
      r.addFrame(rf(0, 0xfffffffe, 1005000));
      final h = r.endPhase(1006000).hands[0];
      expect(h.missing, 0);
      expect(h.gapEvents, 0);
      expect(h.outOfOrder, 2);
    });

    test('statistics restart in each phase', () {
      final r = newRecorder(MemoryCaptureSink());
      r.beginPhase('still', 1000000);
      r.addFrame(rf(0, 10, 1001000));
      r.endPhase(1002000);
      r.beginPhase('twist_cw', 1003000);
      r.addFrame(rf(0, 500, 1004000)); // large jump across phases: no gap
      r.addFrame(rf(0, 501, 1005000));
      final s = r.endPhase(1006000);
      expect(s.hands[0].missing, 0);
      expect(r.summaries, hasLength(2));
    });
  });

  group('volume', () {
    test('nothing is dropped when frames arrive back to back', () {
      final sink = MemoryCaptureSink();
      final r = newRecorder(sink);
      const n = 50000;
      r.beginPhase('still', 1000000);
      for (var i = 0; i < n; i++) {
        r.addFrame(rf(0, i + 1, 1000000 + i * 10));
        r.addFrame(rf(1, i + 1, 1000000 + i * 10 + 5));
      }
      final s = r.endPhase(3000000);
      expect(s.hands[0].frames, n);
      expect(s.hands[1].frames, n);
      expect(s.hands[0].missing, 0);
      final lines = sink.text.split('\n').where((l) => l.startsWith('F '));
      expect(lines, hasLength(2 * n));
    });
  });

  group('files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('capture_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'FileCaptureSink writes the same text and the store lists it',
      () async {
        final store = CaptureStore(Directory('${dir.path}/captures'));
        final file = store.newFile(
          wmrHandRight,
          DateTime(2026, 10, 21, 9, 8, 7),
        );
        final memory = MemoryCaptureSink();
        for (final sink in <CaptureSink>[FileCaptureSink(file), memory]) {
          final r = newRecorder(sink);
          r.beginPhase('still', 1000000);
          r.addFrame(rf(0, 1, 1001000));
          r.endPhase(1002000);
          await r.close();
        }
        expect(file.readAsStringSync(), memory.text);
        final saved = store.list();
        expect(saved.map((c) => c.name), ['right-20261021-090807.txt']);
        expect(saved.single.bytes, memory.text.length);
      },
    );

    test('list ignores other files and an absent directory', () {
      expect(CaptureStore(Directory('${dir.path}/none')).list(), isEmpty);
      File('${dir.path}/notes.txt').writeAsStringSync('x');
      expect(CaptureStore(dir).list(), isEmpty);
    });
  });
}
