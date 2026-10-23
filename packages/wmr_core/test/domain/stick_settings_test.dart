import 'dart:convert';

import 'package:test/test.dart';
import 'package:wmr_core/domain/stick_centre.dart';

const custom = StickSettings(
  config: StickConfig(deadZone: 0.12, learn: false),
  centres: [
    [0.03, 0.148],
    [-0.02, 0.001],
  ],
);

void main() {
  group('json', () {
    test('round trips the config and both rest centres', () {
      final back = stickSettingsFromJson(
        jsonDecode(jsonEncode(stickSettingsToJson(custom))),
      );
      expect(back, custom);
      expect(back!.centreFor(0), [0.03, 0.148]);
      expect(back.centreFor(1), [-0.02, 0.001]);
      expect(
        stickSettingsFromJson(stickSettingsToJson(const StickSettings())),
        const StickSettings(),
      );
    });

    test('a missing centre stays null', () {
      final settings = stickSettingsFromJson({
        'version': 1,
        'deadZone': 0.1,
        'learn': true,
        'centres': [
          null,
          [0.01, 0.02],
        ],
      })!;
      expect(settings.centreFor(0), isNull);
      expect(settings.centreFor(1), [0.01, 0.02]);
    });

    test('bad, missing and out-of-range fields fall back or clamp', () {
      final settings = stickSettingsFromJson({
        'version': 1,
        'deadZone': 9,
        'learn': 'yes',
        'centres': [
          [double.nan, 0.1],
          [0.1],
        ],
      })!;
      const defaults = StickSettings();
      expect(settings.config.deadZone, 0.3); // clamped to the slider range
      expect(settings.config.learn, defaults.config.learn);
      expect(settings.centres, [null, null]);
    });

    test('a non-finite or out-of-range centre is dropped or clamped', () {
      final settings = stickSettingsFromJson({
        'centres': [
          [double.infinity, 0],
          [2, -2],
        ],
      })!;
      expect(settings.centres[0], isNull);
      expect(settings.centres[1], [1, -1]);
    });

    test('not a map or a newer version gives null', () {
      expect(stickSettingsFromJson('x'), isNull);
      expect(stickSettingsFromJson(null), isNull);
      expect(stickSettingsFromJson({'version': 99}), isNull);
      expect(stickSettingsFromJson(<String, Object?>{}), const StickSettings());
    });
  });

  group('StickSettings', () {
    test('copyWith and equality compare the centres by value', () {
      final same = const StickSettings().copyWith(
        centres: [
          [0.1, 0.2],
          null,
        ],
      );
      final other = const StickSettings().copyWith(
        centres: [
          [0.1, 0.2],
          null,
        ],
      );
      expect(same, other);
      expect(same.hashCode, other.hashCode);
      expect(
        same,
        isNot(
          const StickSettings().copyWith(
            centres: [
              [0.1, 0.3],
              null,
            ],
          ),
        ),
      );
    });

    test('centreFor returns null for an unknown hand', () {
      const settings = StickSettings();
      expect(settings.centreFor(-1), isNull);
      expect(settings.centreFor(2), isNull);
    });
  });
}
