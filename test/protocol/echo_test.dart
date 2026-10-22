import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/protocol/echo.dart';

void main() {
  test('request is version, reserved byte and ping_id little-endian', () {
    expect(encodeEchoRequest(0x1234), [0x01, 0x00, 0x34, 0x12]);
    expect(encodeEchoRequest(0x1ffff), [0x01, 0x00, 0xff, 0xff]);
  });

  // WMR_Bridge docs/PROTOCOL.md, "Echo, FF15": ping_id 0x1234, rx_time_us
  // 0x0011223344556677, turnaround_us 1500, queue_depth 0x0102.
  final golden = Uint8List.fromList([
    0x01, 0x00, 0x34, 0x12, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, //
    0x11, 0x00, 0xDC, 0x05, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00,
  ]);

  test('golden answer from the firmware spec', () {
    final r = parseEchoAnswer(golden);
    final a = r.answer!;
    expect(a.pingId, 0x1234);
    expect(a.rxTimeUs, 0x0011223344556677);
    expect(a.turnaroundUs, 1500);
    expect(a.queueDepth, 0x0102);
  });

  test('encode is the inverse of parse', () {
    expect(encodeEchoAnswer(parseEchoAnswer(golden).answer!), golden);
  });

  test('wrong length and unknown version are rejected, not guessed at', () {
    expect(
      parseEchoAnswer(golden.sublist(0, 19)).error,
      EchoParseError.wrongLength,
    );
    expect(parseEchoAnswer(Uint8List(21)).error, EchoParseError.wrongLength);
    final v2 = Uint8List.fromList(golden)..[0] = 2;
    expect(parseEchoAnswer(v2).error, EchoParseError.unknownVersion);
  });

  test('turnaround saturates at the largest u32', () {
    final b = Uint8List.fromList(golden)
      ..[12] = 0xff
      ..[13] = 0xff
      ..[14] = 0xff
      ..[15] = 0xff;
    expect(parseEchoAnswer(b).answer!.turnaroundUs, 0xffffffff);
  });
}
