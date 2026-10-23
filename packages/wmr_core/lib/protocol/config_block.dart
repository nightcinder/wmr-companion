/// Wire format of the bridge's FF13 controller config block characteristic.
///
/// Mirrors WMR_Bridge docs/PROTOCOL.md "Controller config block, FF13" and
/// `src/wmr_cfg.{h,c}`. Pure Dart. The layout was approved by the project
/// owner on 2026-10-22; the firmware read of both controllers' block was
/// reported working (user-reported, WMR_Bridge PR #17). The app side has not
/// been run against the bridge.
library;

import 'dart:typed_data';

const int wmrConfigVersion = 1;
const int wmrConfigHeaderSize = 16;

/// Largest data window per read: 16 + 496 = 512, the ATT value limit.
const int wmrConfigWindowMax = 496;
const int wmrConfigCursorSize = 5;

/// What the bridge reports for one hand's block.
enum ConfigState {
  /// Controller not connected or not tried.
  notRead(0),
  reading(1),
  ready(2),
  failed(3);

  const ConfigState(this.code);
  final int code;

  static ConfigState? fromCode(int code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320, init and final XOR
/// 0xFFFFFFFF). CRC-32 of the ASCII bytes "123456789" is 0xCBF43926.
int crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte & 0xff;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (~crc) & 0xffffffff;
}

/// Cursor write (with response): `hand` u8 (0 LEFT, 1 RIGHT), `offset` u32 LE.
/// An invalid hand makes the bridge answer with ATT error 0x80.
Uint8List encodeConfigCursor(int hand, int offset) {
  final out = Uint8List(wmrConfigCursorSize);
  out[0] = hand;
  ByteData.sublistView(out).setUint32(1, offset, Endian.little);
  return out;
}

/// One read (or notify) value: the 16-byte header and the data window.
class ConfigWindow {
  const ConfigWindow({
    required this.hand,
    required this.state,
    required this.totalLen,
    required this.offset,
    required this.crc32,
    required this.data,
  });

  final int hand;
  final ConfigState state;

  /// Blob length; 0 unless [state] is [ConfigState.ready].
  final int totalLen;

  /// Start of [data] in the blob.
  final int offset;

  /// CRC-32 of the whole blob; 0 unless ready.
  final int crc32;
  final Uint8List data;
}

enum ConfigParseError { tooShort, unknownVersion, unknownState, badHand }

class ConfigParseResult {
  const ConfigParseResult.ok(ConfigWindow this.window) : error = null;
  const ConfigParseResult.error(ConfigParseError this.error) : window = null;

  final ConfigWindow? window;
  final ConfigParseError? error;
}

/// A receiver must ignore a value with an unknown version.
ConfigParseResult parseConfigWindow(Uint8List bytes) {
  if (bytes.length < wmrConfigHeaderSize) {
    return const ConfigParseResult.error(ConfigParseError.tooShort);
  }
  if (bytes[0] != wmrConfigVersion) {
    return const ConfigParseResult.error(ConfigParseError.unknownVersion);
  }
  if (bytes[1] > 1) {
    return const ConfigParseResult.error(ConfigParseError.badHand);
  }
  final state = ConfigState.fromCode(bytes[2]);
  if (state == null) {
    return const ConfigParseResult.error(ConfigParseError.unknownState);
  }
  final d = ByteData.sublistView(bytes);
  return ConfigParseResult.ok(
    ConfigWindow(
      hand: bytes[1],
      state: state,
      totalLen: d.getUint32(4, Endian.little),
      offset: d.getUint32(8, Endian.little),
      crc32: d.getUint32(12, Endian.little),
      data: Uint8List.sublistView(bytes, wmrConfigHeaderSize),
    ),
  );
}

/// What the bridge serves for [hand] at [offset]; the inverse of
/// [parseConfigWindow], for the fake bridge and tests. [blob] is used only
/// when [state] is ready (otherwise total length and CRC are 0 and the
/// window is empty), like the firmware's `wmr_cfg_pack_window`.
Uint8List encodeConfigWindow({
  required int hand,
  required ConfigState state,
  Uint8List? blob,
  int offset = 0,
}) {
  final ready = state == ConfigState.ready && blob != null;
  final total = ready ? blob.length : 0;
  var n = 0;
  if (ready && offset < total) {
    n = total - offset;
    if (n > wmrConfigWindowMax) n = wmrConfigWindowMax;
  }
  final out = Uint8List(wmrConfigHeaderSize + n);
  final d = ByteData.sublistView(out);
  out[0] = wmrConfigVersion;
  out[1] = hand;
  out[2] = state.code;
  d.setUint32(4, total, Endian.little);
  d.setUint32(8, offset, Endian.little);
  d.setUint32(12, ready ? crc32(blob) : 0, Endian.little);
  if (n > 0) out.setRange(wmrConfigHeaderSize, out.length, blob!, offset);
  return out;
}
