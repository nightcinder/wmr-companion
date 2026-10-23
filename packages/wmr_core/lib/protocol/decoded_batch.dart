/// Wire format of the bridge's FF14 batched notifications.
///
/// Mirrors WMR_Bridge `src/wmr_batch.{h,c}` (`wmr_batch_parse`,
/// `wmr_batch_max_count`). See WMR_Bridge docs/PROTOCOL.md, "Batched decoded
/// stream, FF14". Pure Dart. Not verified on hardware.
library;

import 'dart:typed_data';

import 'decoded_record.dart';

const int wmrBatchVersion = 2;

/// `version`, `count`.
const int wmrBatchHeaderSize = 2;

/// ATT opcode and handle in front of every notification value.
const int wmrAttNotifyOverhead = 3;

/// (517 - 3 - 2) / 56: 517 is the largest ATT MTU.
const int wmrBatchMaxCount = 9;

/// Records that fit one FF14 notification at [attMtu], like
/// `wmr_batch_max_count`: 0 below MTU 61, at most [wmrBatchMaxCount].
int batchMaxCount(int attMtu) {
  final n =
      (attMtu - wmrAttNotifyOverhead - wmrBatchHeaderSize) ~/ wmrDecodedSize;
  if (n <= 0) return 0;
  return n > wmrBatchMaxCount ? wmrBatchMaxCount : n;
}

enum BatchParseError {
  /// Shorter than one header and one record.
  tooShort,

  /// Byte 0 is not 2 (an FF12 version 1 record starts with 1).
  unknownVersion,

  /// `count` is 0.
  emptyBatch,

  /// The value is not exactly `2 + 56 x count` bytes.
  wrongLength,
}

class BatchParseResult {
  const BatchParseResult.ok(List<DecodedParseResult> this.records)
    : error = null;
  const BatchParseResult.error(BatchParseError this.error) : records = null;

  /// One result per record, oldest first. A record that does not parse
  /// (unknown record version, bad hand) is an error here and does not
  /// invalidate the others.
  final List<DecodedParseResult>? records;
  final BatchParseError? error;
}

/// Parses one FF14 notification value like `wmr_batch_parse`, then each
/// record like `wmr_decoded_unpack`.
BatchParseResult parseDecodedBatch(Uint8List value) {
  if (value.length < wmrBatchHeaderSize + wmrDecodedSize) {
    return const BatchParseResult.error(BatchParseError.tooShort);
  }
  if (value[0] != wmrBatchVersion) {
    return const BatchParseResult.error(BatchParseError.unknownVersion);
  }
  final count = value[1];
  if (count < 1) {
    return const BatchParseResult.error(BatchParseError.emptyBatch);
  }
  if (value.length != wmrBatchHeaderSize + count * wmrDecodedSize) {
    return const BatchParseResult.error(BatchParseError.wrongLength);
  }
  return BatchParseResult.ok([
    for (var i = 0; i < count; i++)
      parseDecodedRecord(
        Uint8List.sublistView(
          value,
          wmrBatchHeaderSize + i * wmrDecodedSize,
          wmrBatchHeaderSize + (i + 1) * wmrDecodedSize,
        ),
      ),
  ]);
}

/// Packs already encoded 56-byte records into one FF14 value. The app only
/// needs this for the fake bridge and tests.
Uint8List encodeDecodedBatch(List<Uint8List> records) {
  if (records.isEmpty || records.length > 255) {
    throw ArgumentError.value(records.length, 'records', 'must be 1 to 255');
  }
  final out = Uint8List(wmrBatchHeaderSize + records.length * wmrDecodedSize);
  out[0] = wmrBatchVersion;
  out[1] = records.length;
  for (var i = 0; i < records.length; i++) {
    if (records[i].length != wmrDecodedSize) {
      throw ArgumentError('record $i is ${records[i].length} bytes, not 56');
    }
    out.setRange(
      wmrBatchHeaderSize + i * wmrDecodedSize,
      wmrBatchHeaderSize + (i + 1) * wmrDecodedSize,
      records[i],
    );
  }
  return out;
}
