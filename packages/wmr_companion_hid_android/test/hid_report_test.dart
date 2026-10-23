import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_hid_android/wmr_companion_hid_android.dart';

GamepadState pad({
  Set<GamepadButton> buttons = const {},
  List<double> left = const [0, 0],
  List<double> right = const [0, 0],
  double lt = 0,
  double rt = 0,
}) => GamepadState(
  buttons: buttons,
  leftStick: left,
  rightStick: right,
  leftTrigger: lt,
  rightTrigger: rt,
);

void main() {
  test('idle pad: nothing pressed, hat centred, axes zero', () {
    expect(encodeHidReport(pad()), [0, 0, 15, 0, 0, 0, 0, 0, 0]);
    expect(encodeHidReport(pad()).length, hidReportSize);
  });

  test('buttons use the documented bit order', () {
    for (var i = 0; i < hidButtonOrder.length; i++) {
      final r = encodeHidReport(pad(buttons: {hidButtonOrder[i]}));
      expect(r[0] | (r[1] << 8), 1 << i, reason: '${hidButtonOrder[i]}');
    }
    final all = encodeHidReport(pad(buttons: hidButtonOrder.toSet()));
    expect(all[0] | (all[1] << 8), (1 << hidButtonOrder.length) - 1);
  });

  test('d-pad becomes a hat, opposite directions cancel', () {
    int hat(Set<GamepadButton> b) => encodeHidReport(pad(buttons: b))[2];
    const u = GamepadButton.dpadUp,
        d = GamepadButton.dpadDown,
        l = GamepadButton.dpadLeft,
        r = GamepadButton.dpadRight;
    expect(hat({u}), 0);
    expect(hat({u, r}), 1);
    expect(hat({r}), 2);
    expect(hat({d, r}), 3);
    expect(hat({d}), 4);
    expect(hat({d, l}), 5);
    expect(hat({l}), 6);
    expect(hat({u, l}), 7);
    expect(hat({}), hidHatCentred);
    expect(hat({u, d}), hidHatCentred);
    expect(hat({l, r, u}), 0);
  });

  test('sticks scale to +-127, y is inverted, bad values read 0', () {
    final r = encodeHidReport(pad(left: const [1, 1], right: const [-1, -1]))
        .buffer
        .asByteData();
    expect(r.getInt8(3), 127);
    expect(r.getInt8(4), -127); // up in the model is negative Y in HID
    expect(r.getInt8(5), -127);
    expect(r.getInt8(6), 127);
    final half = encodeHidReport(pad(left: const [0.5, -0.5]));
    expect(half.buffer.asByteData().getInt8(3), 64);
    expect(half.buffer.asByteData().getInt8(4), 64); // y -0.5 is down
    final bad = encodeHidReport(pad(left: const [double.nan, 5]));
    expect(bad.buffer.asByteData().getInt8(3), 0);
    expect(bad.buffer.asByteData().getInt8(4), -127); // clamped
  });

  test('triggers scale to 0..255 and clamp', () {
    final r = encodeHidReport(pad(lt: 0.5, rt: 2));
    expect(r[7], 128);
    expect(r[8], 255);
    expect(encodeHidReport(pad(lt: -1))[7], 0);
  });

  test('descriptor is well formed and matches the report size', () {
    final d = hidReportDescriptor;
    expect(d.first, 0x05);
    expect(d.last, 0xC0);
    // Walk the items: every item's data length comes from its prefix.
    var i = 0;
    var open = 0;
    var bits = 0;
    var size = 0;
    var count = 0;
    while (i < d.length) {
      final prefix = d[i];
      final len = switch (prefix & 3) {
        3 => 4,
        final n => n,
      };
      final tag = prefix & 0xFC;
      final value = len == 0 ? 0 : d[i + 1];
      if (tag == 0xA0) open++;
      if (tag == 0xC0) open--;
      if (tag == 0x74) size = value;
      if (tag == 0x94) count = value;
      if (tag == 0x80) bits += size * count; // Input
      i += 1 + len;
    }
    expect(i, d.length);
    expect(open, 0);
    expect(bits, hidReportSize * 8);
    expect(d.sublist(6, 8), [0x85, hidReportId]);
  });
}
