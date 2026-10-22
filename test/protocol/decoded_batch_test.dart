import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/protocol/decoded_batch.dart';
import 'package:wmr_companion/protocol/decoded_record.dart';
import 'package:wmr_companion/protocol/gatt.dart';

import 'decoded_record_test.dart' show golden;

/// `fake_record` from WMR_Bridge `tests/test_batch.c` @ 8f5921a: every byte
/// is [fill], except byte 0 = version 1 and byte 1 = hand.
Uint8List fakeRecord(int hand, int fill) {
  final r = Uint8List(wmrDecodedSize)..fillRange(0, wmrDecodedSize, fill);
  r[0] = wmrDecodedVersion;
  r[1] = hand;
  return r;
}

/// The records `test_golden` uses: hand alternates, fill 0x10 + i.
final List<Uint8List> recs = [
  for (var i = 0; i < wmrBatchMaxCount; i++) fakeRecord(i & 1, 0x10 + i),
];

void main() {
  test('sizes match wmr_batch.h', () {
    expect(wmrBatchVersion, 2);
    expect(wmrBatchHeaderSize, 2);
    expect(wmrBatchedMinMtu, 61);
    expect(wmrBatchHeaderSize + wmrBatchMaxCount * wmrDecodedSize, 506);
  });

  test('records per notification, like wmr_batch_max_count', () {
    const want = {
      0: 0,
      23: 0,
      59: 0,
      60: 0,
      61: 1,
      116: 1,
      117: 2,
      247: 4,
      285: 5,
      517: 9,
      65535: 9,
    };
    for (final e in want.entries) {
      expect(batchMaxCount(e.key), e.value, reason: 'MTU ${e.key}');
    }
    // The largest batch always fits in MTU - 3.
    for (var mtu = wmrBatchedMinMtu; mtu <= 517; mtu++) {
      final n = batchMaxCount(mtu);
      expect(n, greaterThanOrEqualTo(1));
      expect(2 + n * 56, lessThanOrEqualTo(mtu - 3));
    }
  });

  group('golden bytes from test_batch.c', () {
    test('batch of 1', () {
      final b = encodeDecodedBatch([recs[0]]);
      expect(b, hasLength(58));
      expect(b.sublist(0, 5), [0x02, 0x01, 0x01, 0x00, 0x10]);
      expect(b[57], 0x10);
      expect(b.sublist(2), recs[0]);
    });

    test('batch of 2, both hands, oldest first', () {
      final b = encodeDecodedBatch([recs[0], recs[1]]);
      expect(b, hasLength(114));
      expect(b.sublist(0, 2), [0x02, 0x02]);
      expect(b.sublist(58, 61), [0x01, 0x01, 0x11]);
      expect(b[113], 0x11);
      expect(b.sublist(2, 58), recs[0]);
      expect(b.sublist(58), recs[1]);
    });

    test('maximum of 9 (MTU 517)', () {
      final b = encodeDecodedBatch(recs);
      expect(b, hasLength(506));
      expect(b.sublist(0, 2), [0x02, 0x09]);
      for (var i = 0; i < 9; i++) {
        expect(b.sublist(2 + i * 56, 58 + i * 56), recs[i]);
      }
      expect(b[505], 0x18);
    });
  });

  group('parse', () {
    test('round trip of 4 (MTU 247): records in order, hand 1 second', () {
      final b = encodeDecodedBatch(recs.sublist(0, 4));
      expect(b, hasLength(226));
      final parsed = parseDecodedBatch(b);
      expect(parsed.error, isNull);
      final records = parsed.records!;
      expect(records, hasLength(4));
      expect([for (final r in records) r.record!.hand], [0, 1, 0, 1]);
    });

    test('real FF12 records come out unchanged', () {
      final b = encodeDecodedBatch([golden, golden]);
      final records = parseDecodedBatch(b).records!;
      for (final r in records) {
        final want = parseDecodedRecord(golden).record!;
        expect(r.record!.sequence, want.sequence);
        expect(r.record!.deviceTicks, want.deviceTicks);
        expect(r.record!.rxTimeUs, want.rxTimeUs);
        expect(r.record!.gyro, want.gyro);
        expect(encodeDecodedRecord(r.record!), golden);
      }
    });

    BatchParseError? errorOf(Uint8List v) => parseDecodedBatch(v).error;

    test('rejects like wmr_batch_parse', () {
      final b = encodeDecodedBatch(recs.sublist(0, 4));
      expect(errorOf(Uint8List(0)), BatchParseError.tooShort);
      expect(errorOf(b.sublist(0, 57)), BatchParseError.tooShort);
      expect(errorOf(b.sublist(0, b.length - 1)), BatchParseError.wrongLength);
      expect(
        errorOf(Uint8List.fromList([...b, 0])),
        BatchParseError.wrongLength,
      );
      expect(
        errorOf(Uint8List.fromList(b)..[0] = 1),
        BatchParseError.unknownVersion,
      );
      expect(
        errorOf(Uint8List.fromList(b)..[1] = 0),
        BatchParseError.emptyBatch,
      );
      // count disagrees with the length.
      expect(
        errorOf(Uint8List.fromList(b)..[1] = 5),
        BatchParseError.wrongLength,
      );
    });

    test('an FF12 record is not a batch and a batch is not a record', () {
      expect(errorOf(recs[0]), BatchParseError.tooShort);
      expect(errorOf(golden), BatchParseError.tooShort);
      final b = encodeDecodedBatch([golden]);
      expect(parseDecodedRecord(b).error, DecodedParseError.wrongLength);
    });

    test('a bad record fails alone, the others still parse', () {
      final bad = Uint8List.fromList(recs[1])..[1] = 2; // hand 2
      final parsed = parseDecodedBatch(
        encodeDecodedBatch([recs[0], bad, recs[2]]),
      );
      final records = parsed.records!;
      expect(records[0].record, isNotNull);
      expect(records[1].error, DecodedParseError.badHand);
      expect(records[2].record, isNotNull);
    });
  });

  test('encoder refuses empty batches and wrong-sized records', () {
    expect(() => encodeDecodedBatch([]), throwsArgumentError);
    expect(() => encodeDecodedBatch([Uint8List(55)]), throwsArgumentError);
  });
}
