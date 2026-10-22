import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/protocol/decoded_record.dart';

/// `decoded_golden` from WMR_Bridge `tests/test_protocol.c` (branch
/// ff12-decoded-stream, head 8fcb6a1, merged as a0cba83). Same bytes, same
/// field values as `test_decoded_golden`.
final Uint8List golden = Uint8List.fromList(const [
  0x01, 0x01, 0x00, 0x06, // version, hand, flags, buttons
  0x04, 0x03, 0x02, 0x01, // sequence 0x01020304
  0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, // rx_time_us
  0xDD, 0xCC, 0xBB, 0xAA, // device_ticks
  0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x3F,
  0x00, 0x00, 0x80, 0x40, 0x00, 0x00, 0x00, 0xC1, 0x00, 0x00, 0x00, 0x00,
  0xFE, 0xFF, // temperature -2
  0xFF, 0x7F, 0x01, 0x80, // stick 32767 -32767
  0x00, 0x00, 0x00, 0x40, // trackpad 0 16384
  0xFF, 0x7B, // trigger, battery
]);

void main() {
  test('golden bytes are 56 bytes', () => expect(golden, hasLength(56)));

  test('parses the firmware golden packet', () {
    final r = parseDecodedRecord(golden).record!;
    expect(r.hand, 1);
    expect(r.flags, 0);
    expect(r.calibrated, isFalse);
    expect(r.buttons, 0x06);
    expect(r.buttons & wmrBtnHome, isNot(0));
    expect(r.buttons & wmrBtnMenu, isNot(0));
    expect(r.sequence, 0x01020304);
    expect(r.rxTimeUs, 0x1122334455667788);
    expect(r.deviceTicks, 0xAABBCCDD);
    expect(r.gyro, [1.0, -2.0, 0.5]);
    expect(r.accel, [4.0, -8.0, 0.0]);
    expect(r.temperatureRaw, -2);
    expect(r.stick, [32767, -32767]);
    expect(r.trackpad, [0, 16384]);
    expect(r.trigger, 0xFF);
    expect(r.battery, 0x7B);
  });

  test('encoder reproduces the golden bytes', () {
    final r = parseDecodedRecord(golden).record!;
    expect(encodeDecodedRecord(r), golden);
  });

  group('rejects like wmr_decoded_unpack', () {
    DecodedParseError? errorOf(Uint8List v) => parseDecodedRecord(v).error;

    test('truncated and oversized', () {
      expect(
        errorOf(Uint8List.sublistView(golden, 0, 55)),
        DecodedParseError.wrongLength,
      );
      expect(errorOf(Uint8List(0)), DecodedParseError.wrongLength);
      expect(errorOf(Uint8List(12)), DecodedParseError.wrongLength);
      expect(
        errorOf(Uint8List.fromList([...golden, 0])),
        DecodedParseError.wrongLength,
      );
    });

    test('unknown version', () {
      for (final v in [0, 2, 0xFF]) {
        final p = Uint8List.fromList(golden)..[0] = v;
        expect(errorOf(p), DecodedParseError.unknownVersion);
      }
    });

    test('bad hand', () {
      final p = Uint8List.fromList(golden)..[1] = 2;
      expect(errorOf(p), DecodedParseError.badHand);
    });

    test('a raw FF11 fragment is not a decoded record', () {
      final fragment = Uint8List(56)..[0] = 0x52;
      expect(errorOf(fragment), DecodedParseError.unknownVersion);
    });
  });

  test('keeps the calibrated flag so a later version can be detected', () {
    final p = Uint8List.fromList(golden)..[2] = wmrDecodedFlagCalibrated;
    expect(parseDecodedRecord(p).record!.calibrated, isTrue);
  });

  test('passes non-finite floats through for the consumer to reject', () {
    final p = Uint8List.fromList(golden);
    ByteData.sublistView(p).setUint32(20, 0x7FC00000, Endian.little);
    expect(parseDecodedRecord(p).record!.gyro[0].isNaN, isTrue);
  });

  test('tickDelta handles the 32-bit wrap', () {
    expect(tickDelta(100, 160), 60);
    expect(tickDelta(0xFFFFFF00, 0x00000100), 0x200);
    expect(tickDelta(5, 5), 0);
    expect(tickDelta(0xFFFFFFFF, 0), 1);
  });
}
