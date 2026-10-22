/// Extracts Monado's 1024-byte config XOR key from the text of
/// `wmr_config_key.h` (src/xrt/drivers/wmr/, Copyright 2021 Jan Schmidt,
/// BSL-1.0). Pure Dart, used by `tool/fetch_wmr_config_key.dart` and its test.
library;

import 'dart:typed_data';

const int monadoKeySize = 1024;

/// Returns the bytes of the first `{ ... }` initializer in [header], ignoring
/// `//` and `/* */` comments. Throws [FormatException] unless it holds
/// exactly [monadoKeySize] hexadecimal byte values.
Uint8List extractMonadoKey(String header) {
  final noBlock = header.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ');
  final text = noBlock.replaceAll(RegExp(r'//[^\n]*'), ' ');
  final open = text.indexOf('{');
  final close = open < 0 ? -1 : text.indexOf('}', open);
  if (open < 0 || close < 0) {
    throw const FormatException('no { ... } initializer found');
  }
  final body = text.substring(open + 1, close);
  final bytes = <int>[];
  for (final token in body.split(',')) {
    final t = token.trim();
    if (t.isEmpty) continue;
    final m = RegExp(r'^0[xX]([0-9a-fA-F]{1,2})$').firstMatch(t);
    if (m == null) {
      throw FormatException('not a hex byte value: "$t"');
    }
    bytes.add(int.parse(m.group(1)!, radix: 16));
  }
  if (bytes.length != monadoKeySize) {
    throw FormatException(
      'expected $monadoKeySize bytes, found ${bytes.length}',
    );
  }
  return Uint8List.fromList(bytes);
}
