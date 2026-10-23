import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/protocol/config_block.dart';

Uint8List _ramp(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) i]);

void main() {
  test('CRC-32 matches the standard check value', () {
    expect(crc32('123456789'.codeUnits), 0xcbf43926);
    expect(crc32(const []), 0);
    expect(crc32(Uint8List(4)), 0x2144df1c);
  });

  test('cursor write golden bytes (RIGHT, offset 496)', () {
    expect(encodeConfigCursor(1, 496), [0x01, 0xf0, 0x01, 0x00, 0x00]);
    expect(encodeConfigCursor(0, 0), [0, 0, 0, 0, 0]);
  });

  test('window golden bytes match the firmware (wmr_cfg_pack_window)', () {
    // Same blob as WMR_Bridge tests/test_cfg.c: byte i = i & 0xff, 600 bytes.
    // The header and the CRC below were printed by the firmware's C code.
    final blob = _ramp(600);
    expect(crc32(blob), 0x2b00c0c1);

    final second = encodeConfigWindow(
      hand: 1,
      state: ConfigState.ready,
      blob: blob,
      offset: 496,
    );
    expect(second.sublist(0, 16), [
      0x01, 0x01, 0x02, 0x00, 0x58, 0x02, 0x00, 0x00, //
      0xf0, 0x01, 0x00, 0x00, 0xc1, 0xc0, 0x00, 0x2b,
    ]);
    expect(second.length, 16 + 104);
    expect(second.sublist(16), blob.sublist(496));

    final first = encodeConfigWindow(
      hand: 1,
      state: ConfigState.ready,
      blob: blob,
    );
    expect(first.length, 16 + wmrConfigWindowMax);
    expect(first.sublist(16), blob.sublist(0, 496));
  });

  test('a hand that is not ready serves total 0, crc 0 and no data', () {
    for (final s in [
      ConfigState.notRead,
      ConfigState.reading,
      ConfigState.failed,
    ]) {
      final v = encodeConfigWindow(hand: 0, state: s, blob: _ramp(600));
      expect(v.length, 16);
      final w = parseConfigWindow(v).window!;
      expect(w.state, s);
      expect(w.totalLen, 0);
      expect(w.crc32, 0);
      expect(w.data, isEmpty);
    }
    // An offset past the end of a ready blob is a header only.
    expect(
      encodeConfigWindow(
        hand: 1,
        state: ConfigState.ready,
        blob: _ramp(600),
        offset: 600,
      ).length,
      16,
    );
  });

  test('parse round trip and rejection of bad values', () {
    final v = encodeConfigWindow(
      hand: 1,
      state: ConfigState.ready,
      blob: _ramp(10),
    );
    final w = parseConfigWindow(v).window!;
    expect(w.hand, 1);
    expect(w.totalLen, 10);
    expect(w.offset, 0);
    expect(w.data, _ramp(10));

    expect(parseConfigWindow(Uint8List(15)).error, ConfigParseError.tooShort);
    expect(
      parseConfigWindow(Uint8List.fromList([2, ...v.sublist(1)])).error,
      ConfigParseError.unknownVersion,
    );
    expect(
      parseConfigWindow(Uint8List.fromList([v[0], 2, ...v.sublist(2)])).error,
      ConfigParseError.badHand,
    );
    expect(
      parseConfigWindow(Uint8List.fromList([v[0], v[1], 9, ...v.sublist(3)]))
          .error,
      ConfigParseError.unknownState,
    );
  });
}
