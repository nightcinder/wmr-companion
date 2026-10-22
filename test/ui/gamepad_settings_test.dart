import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/gamepad.dart';
import 'package:wmr_companion/services/gamepad_settings_store.dart';
import 'package:wmr_companion/ui/gamepad/gamepad_providers.dart';

class MemoryStore implements GamepadSettingsStore {
  MemoryStore([this.saved]);

  GamepadConfig? saved;
  int saves = 0;
  Completer<void>? loadGate;

  @override
  Future<GamepadConfig?> load() async {
    await loadGate?.future;
    return saved;
  }

  @override
  Future<void> save(GamepadConfig config) async {
    saves++;
    saved = config;
  }
}

const custom = GamepadConfig(
  triggerFullScale: 200,
  triggerDeadZone: 0.1,
  triggerPressThreshold: 0.3,
  trackpadCentreRadius: 0.5,
  leftTrackpad: TrackpadRole.faceButtons,
  rightTrackpad: TrackpadRole.none,
  invertStickY: true,
  invertTrackpadY: true,
  tilt: TiltConfig(
    target: TiltTarget.leftStick,
    hand: 0,
    maxDegrees: 50,
    deadZoneDegrees: 6,
    invertX: true,
    invertY: true,
  ),
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('json', () {
    test('round trips every field', () {
      final back = gamepadConfigFromJson(
        jsonDecode(jsonEncode(gamepadConfigToJson(custom))),
      );
      expect(back, custom);
      expect(
        gamepadConfigFromJson(gamepadConfigToJson(const GamepadConfig())),
        const GamepadConfig(),
      );
    });

    test('bad, missing and out-of-range fields fall back or clamp', () {
      final c = gamepadConfigFromJson({
        'version': 1,
        'triggerFullScale': 9999,
        'triggerDeadZone': 'high',
        'triggerPressThreshold': double.nan,
        'leftTrackpad': 'laser',
        'rightTrackpad': 'dpad',
        'invertStickY': 1,
        'tilt': {'target': 'rightStick', 'hand': 7, 'maxDegrees': 1},
      })!;
      const d = GamepadConfig();
      expect(c.triggerFullScale, 255); // clamped to the slider range
      expect(c.triggerDeadZone, d.triggerDeadZone);
      expect(c.triggerPressThreshold, d.triggerPressThreshold);
      expect(c.leftTrackpad, d.leftTrackpad);
      expect(c.rightTrackpad, TrackpadRole.dpad);
      expect(c.invertStickY, isFalse);
      expect(c.tilt.target, TiltTarget.rightStick);
      expect(c.tilt.hand, 1);
      expect(c.tilt.maxDegrees, 10);
      expect(c.tilt.deadZoneDegrees, d.tilt.deadZoneDegrees);
    });

    test('not a map or a newer version gives null', () {
      expect(gamepadConfigFromJson('x'), isNull);
      expect(gamepadConfigFromJson(null), isNull);
      expect(gamepadConfigFromJson({'version': 99}), isNull);
      expect(gamepadConfigFromJson(<String, Object?>{}), const GamepadConfig());
    });
  });

  group('FileGamepadSettingsStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gamepad_settings'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('saves and loads, and a missing file is null', () async {
      final store = FileGamepadSettingsStore(dir);
      expect(await store.load(), isNull);
      await store.save(custom);
      expect(await FileGamepadSettingsStore(dir).load(), custom);
      expect(File('${dir.path}/gamepad_settings.json.tmp').existsSync(), false);
    });

    test('a corrupt file is ignored', () async {
      File('${dir.path}/gamepad_settings.json').writeAsStringSync('{nope');
      expect(await FileGamepadSettingsStore(dir).load(), isNull);
    });
  });

  group('GamepadConfigNotifier', () {
    ProviderContainer make(MemoryStore store) {
      final c = ProviderContainer(
        overrides: [
          gamepadSettingsStoreProvider.overrideWithValue(store),
          gamepadSaveDelayProvider.overrideWithValue(
            const Duration(milliseconds: 60),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('loads the saved settings after startup', () async {
      final c = make(MemoryStore(custom));
      expect(c.read(gamepadConfigProvider), const GamepadConfig());
      await settle();
      expect(c.read(gamepadConfigProvider), custom);
    });

    test('a change made before the load finishes wins', () async {
      final store = MemoryStore(custom)..loadGate = Completer<void>();
      final c = make(store);
      c.read(gamepadConfigProvider);
      final mine = const GamepadConfig().copyWith(invertStickY: true);
      c.read(gamepadConfigProvider.notifier).set(mine);
      store.loadGate!.complete();
      await settle();
      expect(c.read(gamepadConfigProvider), mine);
    });

    test('saves once after a burst of changes', () async {
      final store = MemoryStore();
      final c = make(store);
      c.read(gamepadConfigProvider);
      final n = c.read(gamepadConfigProvider.notifier);
      for (var v = 100; v <= 150; v += 10) {
        n.set(c.read(gamepadConfigProvider).copyWith(triggerFullScale: v));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(store.saves, 0);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(store.saves, 1);
      expect(store.saved!.triggerFullScale, 150);
    });

    test('reset saves the defaults', () async {
      final store = MemoryStore(custom);
      final c = make(store);
      c.read(gamepadConfigProvider);
      await settle();
      c.read(gamepadConfigProvider.notifier).reset();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(store.saved, const GamepadConfig());
    });

    test('disposing flushes a pending save', () async {
      final store = MemoryStore();
      final c = ProviderContainer(
        overrides: [gamepadSettingsStoreProvider.overrideWithValue(store)],
      );
      c.read(gamepadConfigProvider);
      c.read(gamepadConfigProvider.notifier).set(custom);
      c.dispose();
      await settle();
      expect(store.saved, custom);
    });
  });
}
