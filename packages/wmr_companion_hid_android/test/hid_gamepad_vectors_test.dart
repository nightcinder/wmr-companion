// Shared input->report vectors, firmware (WMR_Bridge) and companion side.
//
// test/vectors/hid_gamepad.txt and hid_report_descriptor.txt are byte copies of
// WMR_Bridge tests/vectors/*. Change both repositories in the same change.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_hid_android/wmr_companion_hid_android.dart';
import 'package:wmr_core/domain/gamepad.dart';

File vector(String name) {
  final direct = File('test/vectors/$name');
  if (direct.existsSync()) return direct;
  return File('packages/wmr_companion_hid_android/test/vectors/$name');
}

HandInput hand(List<String> f, int at) {
  if (f[at] == '0')
    return HandInput(); // connected flag is checked by the caller
  return HandInput(
    buttons: int.parse(f[at + 1]),
    stick: [double.parse(f[at + 2]), double.parse(f[at + 3])],
    trigger: int.parse(f[at + 4]),
    trackpad: [double.parse(f[at + 5]), double.parse(f[at + 6])],
  );
}

void main() {
  test('descriptor is byte for byte the firmware descriptor', () {
    final text = vector('hid_report_descriptor.txt').readAsStringSync();
    final expected = <int>[
      for (final line in text.split('\n'))
        if (!line.startsWith('#'))
          for (final token in line.trim().split(RegExp(r'\s+')))
            if (token.isNotEmpty) int.parse(token, radix: 16),
    ];
    expect(hidReportDescriptor, expected);
  });

  test('shared vectors map to the same report', () {
    final lines = vector('hid_gamepad.txt')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
        .toList();
    expect(lines.length, greaterThanOrEqualTo(20));

    for (final line in lines) {
      final f = line.trim().split(RegExp(r'\s+'));
      expect(f.length, 30, reason: f.first);
      final left = hand(f, 1);
      final right = hand(f, 8);
      final config = GamepadConfig(
        invertStickY: f[17] == '1',
        invertTrackpadY: f[18] == '1',
        leftTrackpad: TrackpadRole.values[int.parse(f[19])],
        rightTrackpad: TrackpadRole.values[int.parse(f[20])],
      );
      final previous = GamepadState(
        buttons: {
          if (f[15] == '1') GamepadButton.l2,
          if (f[16] == '1') GamepadButton.r2,
        },
      );
      final report = encodeHidReport(
        mapGamepad(
          f[1] == '0' ? null : left,
          f[8] == '0' ? null : right,
          config,
          previous: previous,
        ),
      );
      final expected = [for (var i = 21; i < 30; i++) int.parse(f[i])];
      expect(report, expected, reason: f.first);
    }
  });
}
