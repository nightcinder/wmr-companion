/// Wire format of the bridge's FF15 echo characteristic.
///
/// Mirrors WMR_Bridge docs/PROTOCOL.md "Echo, FF15" and `src/wmr_echo.{h,c}`.
/// Pure Dart. Firmware merged, not verified on hardware.
library;

import 'dart:typed_data';

const int wmrEchoVersion = 1;
const int wmrEchoRequestSize = 4;
const int wmrEchoAnswerSize = 20;

/// Request: version, reserved, `ping_id` u16 little-endian.
Uint8List encodeEchoRequest(int pingId) {
  final out = Uint8List(wmrEchoRequestSize);
  out[0] = wmrEchoVersion;
  ByteData.sublistView(out).setUint16(2, pingId & 0xffff, Endian.little);
  return out;
}

/// One answer. All times are on the ESP32 clock, the same one as FF12
/// `rx_time_us`.
class EchoAnswer {
  const EchoAnswer({
    required this.pingId,
    required this.rxTimeUs,
    required this.turnaroundUs,
    required this.queueDepth,
  });

  final int pingId;

  /// When the request reached the ESP32's ATT write callback.
  final int rxTimeUs;

  /// From [rxTimeUs] to just before the answer was handed to the stack;
  /// saturates at 0xFFFFFFFF.
  final int turnaroundUs;

  /// Stream frames queued when the request arrived.
  final int queueDepth;
}

enum EchoParseError { wrongLength, unknownVersion }

class EchoParseResult {
  const EchoParseResult.ok(EchoAnswer this.answer) : error = null;
  const EchoParseResult.error(EchoParseError this.error) : answer = null;

  final EchoAnswer? answer;
  final EchoParseError? error;
}

/// A receiver must ignore an answer with an unknown version.
EchoParseResult parseEchoAnswer(Uint8List bytes) {
  if (bytes.length != wmrEchoAnswerSize) {
    return const EchoParseResult.error(EchoParseError.wrongLength);
  }
  if (bytes[0] != wmrEchoVersion) {
    return const EchoParseResult.error(EchoParseError.unknownVersion);
  }
  final d = ByteData.sublistView(bytes);
  const e = Endian.little;
  return EchoParseResult.ok(
    EchoAnswer(
      pingId: d.getUint16(2, e),
      rxTimeUs: d.getUint64(4, e),
      turnaroundUs: d.getUint32(12, e),
      queueDepth: d.getUint16(16, e),
    ),
  );
}

/// Inverse of [parseEchoAnswer], for the fake bridge and tests.
Uint8List encodeEchoAnswer(EchoAnswer a) {
  final out = Uint8List(wmrEchoAnswerSize);
  final d = ByteData.sublistView(out);
  const e = Endian.little;
  out[0] = wmrEchoVersion;
  d.setUint16(2, a.pingId, e);
  d.setUint64(4, a.rxTimeUs, e);
  d.setUint32(12, a.turnaroundUs, e);
  d.setUint16(16, a.queueDepth, e);
  return out;
}
