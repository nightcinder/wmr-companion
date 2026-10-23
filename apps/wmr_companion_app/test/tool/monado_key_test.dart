import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/monado_key.dart';

/// A synthetic header shaped like Monado's: comments, a declaration, 1024
/// values in rows of 16. NOT Monado's table.
String _header({int count = 1024, String extra = ''}) {
  final rows = <String>[];
  for (var i = 0; i < count; i += 16) {
    final row = [
      for (var j = i; j < i + 16 && j < count; j++)
        '0x${((j * 7 + 3) & 0xff).toRadixString(16).padLeft(2, '0')}',
    ];
    rows.add('\t${row.join(', ')},');
  }
  return '''
// Copyright 2021 Someone
// SPDX-License-Identifier: BSL-1.0
/* the key {0x99, 0x98} is XORed with the config */
#pragma once
// clang-format off
static const uint8_t wmr_config_key[] = {
${rows.join('\n')}$extra
};
// clang-format on
''';
}

void main() {
  test('extracts 1024 bytes and ignores comments', () {
    final key = extractMonadoKey(_header());
    expect(key.length, 1024);
    expect(key[0], 3);
    expect(key[1], 10);
    expect(key[1023], (1023 * 7 + 3) & 0xff);
  });

  test('rejects a wrong count', () {
    expect(() => extractMonadoKey(_header(count: 1008)), throwsFormatException);
  });

  test('rejects a non-hex value and a missing initializer', () {
    expect(
      () => extractMonadoKey(_header(extra: '\n\t12,')),
      throwsFormatException,
    );
    expect(() => extractMonadoKey('int x;'), throwsFormatException);
  });
}
