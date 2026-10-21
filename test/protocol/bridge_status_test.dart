import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/protocol/bridge_status.dart';

void main() {
  test('parses the 16-byte status value', () {
    final s = BridgeStatus.parse(
      Uint8List.fromList([
        0x01, 0x02, 0x03, 0x00, // version 1, RIGHT connected, both HID
        0x10, 0x27, 0x00, 0x00, // 10000 s
        0x05, 0x00, 0x00, 0x00, // LEFT 5
        0x00, 0x01, 0x00, 0x00, // RIGHT 256
      ]),
    )!;
    expect(s.version, 1);
    expect(s.connected, [false, true]);
    expect(s.hidDescriptorReceived, [true, true]);
    expect(s.uptimeSeconds, 10000);
    expect(s.reportsReceived, [5, 256]);
  });

  test('rejects a short value', () {
    expect(BridgeStatus.parse(Uint8List(15)), isNull);
  });
}
