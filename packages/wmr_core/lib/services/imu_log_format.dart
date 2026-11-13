import 'dart:typed_data';

import '../protocol/decoded_record.dart' show wmrDecodedSize;

/// Binary raw-IMU log (FF12 / FF14 stream), format version 1.
///
/// File layout, all integers little-endian:
///
///   header, 64 bytes:
///     0..7    magic "WMRIMU01"
///     8..9    format version (u16) = 1
///     10      stream: 12 (FF12) or 14 (FF14)
///     11      clock id: 1 = phone monotonic (receivedAtUs)
///     12..13  ATT MTU in use (u16)
///     14..21  start time, phone monotonic microseconds (u64)
///     22..59  reserved, zero
///     60..63  CRC-32 (IEEE) of bytes 0..59
///
///   records, each starting with a type byte and a length byte that is the
///   total record length including those two bytes. A reader can skip a
///   record of a type it does not know.
///
///   0x01 IMU sample, length 68:
///     2       bridge index
///     3       batch position (high nibble) and batch count (low nibble);
///             both 0 for a single FF12 notification
///     4..11   received_at_us (u64), phone monotonic, stamped first in the
///             BLE listener
///     12..67  the 56-byte FF12 record, verbatim
///   0x03 EVENT, length 13:
///     2       event code (caller-defined)
///     3       bridge index
///     4       hand (0 left, 1 right; 0xFF none)
///     5..12   received_at_us (u64)
///   0x06 STATS, length 32:
///     2       bridge index, 0xFF = all bridges
///     3       reserved, zero
///     4..11   received_at_us (u64)
///     12..15  records_written (u32): records before this record in the file
///     16..19  sequence gaps, left hand (u32)
///     20..23  sequence gaps, right hand (u32)
///     24..27  out-of-order or repeated sequences, left hand (u32)
///     28..31  out-of-order or repeated sequences, right hand (u32)
///
/// Each IMU record keeps the FF12 bytes unchanged, so no decoding choice made
/// later can lose data. Records are not individually checksummed; the header
/// CRC only protects the header.
const int imuLogHeaderSize = 64;
const int imuLogVersion = 1;
const int imuLogClockPhoneMonotonic = 1;
const int imuLogTypeImu = 0x01;
const int imuLogTypeEvent = 0x03;
const int imuLogTypeStats = 0x06;
const int imuLogImuLength = 2 + 2 + 8 + wmrDecodedSize;
const int imuLogEventLength = 13;
const int imuLogStatsLength = 32;
const int imuLogBridgeAll = 0xff;
const int imuLogHandNone = 0xff;

const List<int> imuLogMagic = [
  0x57, 0x4d, 0x52, 0x49, 0x4d, 0x55, 0x30, 0x31, // "WMRIMU01"
];

/// Standard CRC-32 (reflected, polynomial 0xEDB88320).
int imuLogCrc32(Uint8List data, {int start = 0, int? end}) {
  final stop = end ?? data.length;
  var crc = 0xffffffff;
  for (var i = start; i < stop; i++) {
    crc = _crcTable[(crc ^ data[i]) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c & 0xffffffff;
});

/// The 64-byte file header for a stream.
Uint8List encodeImuLogHeader({
  required int stream,
  required int mtu,
  required int startUs,
}) {
  final out = Uint8List(imuLogHeaderSize);
  final d = ByteData.sublistView(out);
  out.setRange(0, imuLogMagic.length, imuLogMagic);
  d.setUint16(8, imuLogVersion, Endian.little);
  out[10] = stream;
  out[11] = imuLogClockPhoneMonotonic;
  d.setUint16(12, mtu, Endian.little);
  d.setUint64(14, startUs, Endian.little);
  d.setUint32(60, imuLogCrc32(out, end: 60), Endian.little);
  return out;
}

/// One IMU record: the 56-byte FF12 [record] kept verbatim, plus where it
/// came from. [position] and [count] describe its place in an FF14 batch.
Uint8List encodeImuSample({
  required int bridge,
  required int position,
  required int count,
  required int receivedAtUs,
  required Uint8List record,
}) {
  if (record.length != wmrDecodedSize) {
    throw ArgumentError.value(record.length, 'record', 'must be 56 bytes');
  }
  if (position < 0 || position > 15 || count < 0 || count > 15) {
    throw ArgumentError('batch position and count must fit a nibble');
  }
  final out = Uint8List(imuLogImuLength);
  final d = ByteData.sublistView(out);
  out[0] = imuLogTypeImu;
  out[1] = imuLogImuLength;
  out[2] = bridge & 0xff;
  out[3] = ((position & 0x0f) << 4) | (count & 0x0f);
  d.setUint64(4, receivedAtUs, Endian.little);
  out.setRange(12, imuLogImuLength, record);
  return out;
}

Uint8List encodeImuEvent({
  required int code,
  required int bridge,
  required int hand,
  required int receivedAtUs,
}) {
  final out = Uint8List(imuLogEventLength);
  final d = ByteData.sublistView(out);
  out[0] = imuLogTypeEvent;
  out[1] = imuLogEventLength;
  out[2] = code & 0xff;
  out[3] = bridge & 0xff;
  out[4] = hand & 0xff;
  d.setUint64(5, receivedAtUs, Endian.little);
  return out;
}

Uint8List encodeImuStats({
  required int bridge,
  required int receivedAtUs,
  required int recordsWritten,
  required int gapsLeft,
  required int gapsRight,
  required int outOfOrderLeft,
  required int outOfOrderRight,
}) {
  final out = Uint8List(imuLogStatsLength);
  final d = ByteData.sublistView(out);
  out[0] = imuLogTypeStats;
  out[1] = imuLogStatsLength;
  out[2] = bridge & 0xff;
  d.setUint64(4, receivedAtUs, Endian.little);
  d.setUint32(12, recordsWritten & 0xffffffff, Endian.little);
  d.setUint32(16, gapsLeft & 0xffffffff, Endian.little);
  d.setUint32(20, gapsRight & 0xffffffff, Endian.little);
  d.setUint32(24, outOfOrderLeft & 0xffffffff, Endian.little);
  d.setUint32(28, outOfOrderRight & 0xffffffff, Endian.little);
  return out;
}
