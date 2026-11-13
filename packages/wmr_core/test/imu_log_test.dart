import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/imu_log_files.dart';
import 'package:wmr_core/services/imu_log_format.dart';
import 'package:wmr_core/services/imu_log_reader.dart';
import 'package:wmr_core/services/imu_log_recorder.dart';

import 'protocol/decoded_record_test.dart' show golden;

class _MemorySink implements ImuLogSink {
  final List<Uint8List> chunks = [];
  bool closed = false;
  bool accept = true;

  @override
  bool add(Uint8List chunk) {
    if (!accept) return false;
    chunks.add(chunk);
    return true;
  }

  @override
  Future<void> close() async => closed = true;

  Uint8List get bytes {
    final out = BytesBuilder();
    for (final c in chunks) {
      out.add(c);
    }
    return out.toBytes();
  }
}

Uint8List _record({
  required int hand,
  required int sequence,
  int rxTimeUs = 0,
  int deviceTicks = 0,
}) => encodeDecodedRecord(
  DecodedRecord(
    hand: hand,
    sequence: sequence,
    rxTimeUs: rxTimeUs,
    deviceTicks: deviceTicks,
    gyro: const [0.1, -0.2, 0.3],
    accel: const [0.0, 9.8, 0.0],
  ),
);

ImuLogRecorder _recorder(_MemorySink sink, {int stream = 14}) =>
    ImuLogRecorder(sink: sink, stream: stream, mtu: 517, startUs: 1000);

void main() {
  group('CRC-32', () {
    test('matches the standard check value', () {
      final data = Uint8List.fromList('123456789'.codeUnits);
      expect(imuLogCrc32(data), 0xcbf43926);
    });
  });

  group('header', () {
    test('layout and CRC', () {
      final h = encodeImuLogHeader(stream: 14, mtu: 517, startUs: 42);
      expect(h.length, imuLogHeaderSize);
      expect(String.fromCharCodes(h.sublist(0, 8)), 'WMRIMU01');
      final d = ByteData.sublistView(h);
      expect(d.getUint16(8, Endian.little), 1);
      expect(h[10], 14);
      expect(h[11], imuLogClockPhoneMonotonic);
      expect(d.getUint16(12, Endian.little), 517);
      expect(d.getUint64(14, Endian.little), 42);
      expect(d.getUint32(60, Endian.little), imuLogCrc32(h, end: 60));
    });

    test('reader rejects bad magic, bad CRC and unknown version', () {
      final good = encodeImuLogHeader(stream: 12, mtu: 59, startUs: 0);
      final badMagic = Uint8List.fromList(good)..[0] = 0x58;
      expect(() => WmrImuReader.open(badMagic), throwsFormatException);

      final badCrc = Uint8List.fromList(good)..[30] ^= 1;
      expect(() => WmrImuReader.open(badCrc), throwsFormatException);

      final v2 = Uint8List.fromList(good)..[8] = 2;
      final d = ByteData.sublistView(v2);
      d.setUint32(60, imuLogCrc32(v2, end: 60), Endian.little);
      expect(() => WmrImuReader.open(v2), throwsFormatException);

      expect(() => WmrImuReader.open(Uint8List(10)), throwsFormatException);
    });
  });

  group('round trip', () {
    test('FF12 single record and FF14 batch keep the bytes verbatim', () async {
      final sink = _MemorySink();
      final rec = _recorder(sink, stream: 12);
      final single = Uint8List.fromList(golden);
      rec.onStreamValue(single, 5000, 'bridge-a');

      final r1 = _record(hand: wmrHandRight, sequence: 7, deviceTicks: 9);
      final r2 = _record(hand: wmrHandLeft, sequence: 3, deviceTicks: 11);
      final batch = encodeDecodedBatch([r1, r2]);
      rec.onStreamValue(batch, 20000, 'bridge-b');
      rec.onStreamValue(Uint8List(10), 21000, 'bridge-b'); // ignored
      rec.onStreamValue(
        Uint8List.fromList([2, 3, ...List<int>.filled(56, 0)]),
        22000,
        'bridge-b',
      ); // count mismatch, ignored
      await rec.close(receivedAtUs: 30000);

      final reader = WmrImuReader.open(sink.bytes);
      expect(reader.header.stream, 12);
      expect(reader.header.startUs, 1000);
      expect(reader.truncatedTail, isFalse);
      expect(reader.corrupt, isFalse);

      final samples = reader.entries.whereType<ImuLogSample>().toList();
      expect(samples.length, 3);
      expect(samples[0].bridge, 0);
      expect(samples[0].position, 0);
      expect(samples[0].count, 0);
      expect(samples[0].receivedAtUs, 5000);
      expect(samples[0].record, single);

      expect(samples[1].bridge, 1);
      expect(samples[1].position, 0);
      expect(samples[1].count, 2);
      expect(samples[1].receivedAtUs, 20000);
      expect(samples[1].record, r1);
      expect(samples[2].position, 1);
      expect(samples[2].record, r2);
    });

    test('sequence gaps and out-of-order counts reach STATS', () {
      final sink = _MemorySink();
      final rec = _recorder(sink);
      for (final seq in [10, 11, 14, 14]) {
        rec.onStreamValue(
          _record(hand: wmrHandLeft, sequence: seq),
          seq * 100,
          'b',
        );
      }
      rec.onStreamValue(_record(hand: wmrHandRight, sequence: 1), 2000, 'b');
      rec.onStreamValue(_record(hand: wmrHandRight, sequence: 4), 2100, 'b');
      final written = rec.recordsWritten;
      final closing = rec.close(receivedAtUs: 3000);

      return closing.then((_) {
        final reader = WmrImuReader.open(sink.bytes);
        final stats = reader.entries.whereType<ImuLogStats>().last;
        expect(stats.recordsWritten, written);
        expect(stats.gapsLeft, 2); // 11 -> 14 skipped 12 and 13
        expect(stats.outOfOrderLeft, 1); // repeated 14
        expect(stats.gapsRight, 2); // 1 -> 4 skipped 2 and 3
        expect(stats.outOfOrderRight, 0);
        expect(sink.closed, isTrue);
      });
    });

    test('events and an unknown record type are read in order', () {
      final sink = _MemorySink();
      final rec = _recorder(sink);
      rec.recordEvent(
        code: 9,
        sourceDeviceId: 'bridge-a',
        hand: wmrHandLeft,
        receivedAtUs: 1500,
      );
      rec.flush();
      return rec.close(receivedAtUs: 1600).then((_) {
        final bytes = BytesBuilder()
          ..add(sink.bytes)
          ..add([0x7e, 5, 1, 2, 3]);
        final event = encodeImuEvent(
          code: 4,
          bridge: 0,
          hand: wmrHandRight,
          receivedAtUs: 1700,
        );
        bytes.add(event);
        final reader = WmrImuReader.open(bytes.toBytes());
        expect(reader.corrupt, isFalse);
        final ev = reader.entries.whereType<ImuLogEvent>().toList();
        expect(ev.map((e) => e.code), [9, 4]);
        expect(ev.first.hand, wmrHandLeft);
        expect(ev.last.receivedAtUs, 1700);
        final unknown = reader.entries.whereType<ImuLogUnknown>().single;
        expect(unknown.type, 0x7e);
        expect(unknown.bytes, [0x7e, 5, 1, 2, 3]);
      });
    });

    test('a truncated last record is reported, earlier ones kept', () {
      final sink = _MemorySink();
      final rec = _recorder(sink, stream: 12);
      rec.onStreamValue(golden, 100, 'b');
      rec.onStreamValue(golden, 200, 'b');
      rec.flush();
      final whole = sink.bytes;
      final cut = Uint8List.sublistView(whole, 0, whole.length - 5);
      final reader = WmrImuReader.open(cut);
      expect(reader.truncatedTail, isTrue);
      expect(reader.corrupt, isFalse);
      expect(reader.entries.whereType<ImuLogSample>().length, 1);
    });

    test('a known record with a wrong length stops the read as corrupt', () {
      final sink = _MemorySink();
      final rec = _recorder(sink, stream: 12);
      rec.onStreamValue(golden, 100, 'b');
      rec.flush();
      final bytes = Uint8List.fromList(sink.bytes);
      bytes[imuLogHeaderSize + 1] = 10; // IMU record claims length 10
      final reader = WmrImuReader.open(bytes);
      expect(reader.corrupt, isTrue);
      expect(reader.entries, isEmpty);
    });
  });

  group('handoff', () {
    test('a chunk is handed off at 16 KiB and at 50 ms', () {
      final sink = _MemorySink();
      final rec = _recorder(sink, stream: 12);
      final r = _record(hand: wmrHandLeft, sequence: 1);
      rec.onStreamValue(r, 1000, 'b');
      expect(sink.chunks, isEmpty);
      rec.onStreamValue(_record(hand: wmrHandLeft, sequence: 2), 51000, 'b');
      expect(sink.chunks.length, 1);
      expect(rec.chunksRefused, 0);
    });

    test('a refusing sink drops the chunk and counts it', () {
      final sink = _MemorySink()..accept = false;
      final rec = _recorder(sink, stream: 12);
      rec.onStreamValue(golden, 100, 'b');
      rec.flush();
      rec.flush();
      expect(rec.chunksRefused, 1);
      expect(() => rec.close(receivedAtUs: 200), returnsNormally);
    });
  });

  group('file sink', () {
    test('writes a log that the reader opens', () async {
      final dir = Directory.systemTemp.createTempSync('imu_log_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/log.wmrimu');
      final sink = ImuLogFileSink(file);
      final rec = ImuLogRecorder(sink: sink, stream: 12, mtu: 59, startUs: 0);
      rec.onStreamValue(golden, 100, 'b');
      rec.onStreamValue(golden, 200, 'b');
      await rec.close(receivedAtUs: 300);
      expect(sink.error, isNull);
      final reader = WmrImuReader.open(file.readAsBytesSync());
      expect(reader.entries.whereType<ImuLogSample>().length, 2);
      expect(reader.truncatedTail, isFalse);
    });

    test('refuses writes past the outstanding limit', () async {
      final dir = Directory.systemTemp.createTempSync('imu_log_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sink = ImuLogFileSink(
        File('${dir.path}/small.wmrimu'),
        maxOutstandingBytes: 100,
      );
      expect(sink.add(Uint8List(80)), isTrue);
      expect(sink.add(Uint8List(80)), isFalse);
      await sink.close();
    });
  });
}
