import 'dart:typed_data';

import '../protocol/decoded_record.dart' show wmrDecodedSize;
import 'imu_log_format.dart';

/// Header of a raw IMU log, checked by [ImuLogReader.open].
class ImuLogHeader {
  const ImuLogHeader({
    required this.version,
    required this.stream,
    required this.clockId,
    required this.mtu,
    required this.startUs,
  });

  final int version;
  final int stream;
  final int clockId;
  final int mtu;
  final int startUs;
}

sealed class ImuLogEntry {
  const ImuLogEntry();
}

/// One FF12 record, with its FF14 batch position and count (0, 0 for FF12).
class ImuLogSample extends ImuLogEntry {
  const ImuLogSample({
    required this.bridge,
    required this.position,
    required this.count,
    required this.receivedAtUs,
    required this.record,
  });

  final int bridge;
  final int position;
  final int count;
  final int receivedAtUs;

  /// The 56-byte FF12 record, unchanged.
  final Uint8List record;
}

class ImuLogEvent extends ImuLogEntry {
  const ImuLogEvent({
    required this.code,
    required this.bridge,
    required this.hand,
    required this.receivedAtUs,
  });

  final int code;
  final int bridge;
  final int hand;
  final int receivedAtUs;
}

class ImuLogStats extends ImuLogEntry {
  const ImuLogStats({
    required this.bridge,
    required this.receivedAtUs,
    required this.recordsWritten,
    required this.gapsLeft,
    required this.gapsRight,
    required this.outOfOrderLeft,
    required this.outOfOrderRight,
  });

  final int bridge;
  final int receivedAtUs;
  final int recordsWritten;
  final int gapsLeft;
  final int gapsRight;
  final int outOfOrderLeft;
  final int outOfOrderRight;
}

/// A record of a type this reader does not know. Skipped by its length.
class ImuLogUnknown extends ImuLogEntry {
  const ImuLogUnknown(this.type, this.bytes);

  final int type;
  final Uint8List bytes;
}

/// Reads a whole log held in memory. A truncated last record (a crash during
/// a write) ends the list and sets [truncatedTail]. A known record whose
/// length byte does not match its type stops the read and sets [corrupt].
class ImuLogReader {
  ImuLogReader._(this.header, this.entries, this.truncatedTail, this.corrupt);

  final ImuLogHeader header;
  final List<ImuLogEntry> entries;
  final bool truncatedTail;
  final bool corrupt;

  /// Throws [FormatException] when the magic, version or header CRC is wrong.
  factory ImuLogReader.open(Uint8List bytes) {
    if (bytes.length < imuLogHeaderSize) {
      throw const FormatException('IMU log shorter than its header');
    }
    for (var i = 0; i < imuLogMagic.length; i++) {
      if (bytes[i] != imuLogMagic[i]) {
        throw const FormatException('not an IMU log (bad magic)');
      }
    }
    final d = ByteData.sublistView(bytes);
    final stored = d.getUint32(60, Endian.little);
    if (imuLogCrc32(bytes, end: 60) != stored) {
      throw const FormatException('IMU log header CRC mismatch');
    }
    final version = d.getUint16(8, Endian.little);
    if (version != imuLogVersion) {
      throw FormatException('unsupported IMU log version $version');
    }
    final header = ImuLogHeader(
      version: version,
      stream: bytes[10],
      clockId: bytes[11],
      mtu: d.getUint16(12, Endian.little),
      startUs: d.getUint64(14, Endian.little),
    );

    final entries = <ImuLogEntry>[];
    var truncated = false;
    var corrupt = false;
    var pos = imuLogHeaderSize;
    while (pos < bytes.length) {
      if (pos + 2 > bytes.length) {
        truncated = true;
        break;
      }
      final type = bytes[pos];
      final length = bytes[pos + 1];
      if (length < 2) {
        corrupt = true;
        break;
      }
      if (pos + length > bytes.length) {
        truncated = true;
        break;
      }
      final body = Uint8List.sublistView(bytes, pos, pos + length);
      final bd = ByteData.sublistView(body);
      final expected = switch (type) {
        imuLogTypeImu => imuLogImuLength,
        imuLogTypeEvent => imuLogEventLength,
        imuLogTypeStats => imuLogStatsLength,
        _ => -1,
      };
      if (expected == -1) {
        entries.add(ImuLogUnknown(type, Uint8List.fromList(body)));
      } else if (length != expected) {
        corrupt = true;
        break;
      } else if (type == imuLogTypeImu) {
        entries.add(
          ImuLogSample(
            bridge: body[2],
            position: body[3] >> 4,
            count: body[3] & 0x0f,
            receivedAtUs: bd.getUint64(4, Endian.little),
            record: Uint8List.fromList(
              Uint8List.sublistView(body, 12, 12 + wmrDecodedSize),
            ),
          ),
        );
      } else if (type == imuLogTypeEvent) {
        entries.add(
          ImuLogEvent(
            code: body[2],
            bridge: body[3],
            hand: body[4],
            receivedAtUs: bd.getUint64(5, Endian.little),
          ),
        );
      } else {
        entries.add(
          ImuLogStats(
            bridge: body[2],
            receivedAtUs: bd.getUint64(4, Endian.little),
            recordsWritten: bd.getUint32(12, Endian.little),
            gapsLeft: bd.getUint32(16, Endian.little),
            gapsRight: bd.getUint32(20, Endian.little),
            outOfOrderLeft: bd.getUint32(24, Endian.little),
            outOfOrderRight: bd.getUint32(28, Endian.little),
          ),
        );
      }
      pos += length;
    }
    return ImuLogReader._(header, entries, truncated, corrupt);
  }
}
