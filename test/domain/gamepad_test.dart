import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_companion/domain/gamepad.dart';
import 'package:wmr_companion/domain/hand_pipeline.dart';
import 'package:wmr_companion/domain/orientation.dart';
import 'package:wmr_companion/domain/tick_timer.dart';
import 'package:wmr_companion/protocol/decoded_record.dart';

const cfg = GamepadConfig();
const deg = math.pi / 180;

HandInput hand({
  int buttons = 0,
  List<double> stick = const [0, 0],
  int trigger = 0,
  List<double> trackpad = const [0, 0],
  vm.Quaternion? orientation,
}) => HandInput(
  buttons: buttons,
  stick: stick,
  trigger: trigger,
  trackpad: trackpad,
  orientation: orientation,
);

const click = wmrBtnTrackpadClick | wmrBtnTrackpadTouch;

void main() {
  test('no input maps to an idle, disconnected pad', () {
    final s = mapGamepad(null, null, cfg);
    expect(s.buttons, isEmpty);
    expect(s.leftStick, [0, 0]);
    expect(s.rightTrigger, 0);
    expect(s.leftConnected, isFalse);
    expect(s.rightConnected, isFalse);
  });

  test('buttons map per hand', () {
    final s = mapGamepad(
      hand(buttons: wmrBtnSqueeze | wmrBtnThumbstickClick | wmrBtnMenu),
      hand(buttons: wmrBtnSqueeze | wmrBtnMenu | wmrBtnHome | wmrBtnBtPairing),
      cfg,
    );
    expect(s.buttons, {
      GamepadButton.l1,
      GamepadButton.l3,
      GamepadButton.select,
      GamepadButton.r1,
      GamepadButton.start,
      GamepadButton.guide,
    });
    expect(s.leftConnected && s.rightConnected, isTrue);
  });

  test('sticks pass through, y inverts on request, NaN reads 0', () {
    final s = mapGamepad(
      hand(stick: const [0.25, -0.5]),
      hand(stick: const [double.nan, 0.75]),
      cfg,
    );
    expect(s.leftStick, [0.25, -0.5]);
    expect(s.rightStick, [0, 0.75]);
    final inv = mapGamepad(
      hand(stick: const [0.25, -0.5]),
      null,
      cfg.copyWith(invertStickY: true),
    );
    expect(inv.leftStick, [0.25, 0.5]);
  });

  group('triggers', () {
    test('dead zone, rescale and full scale', () {
      expect(triggerValue(0, cfg), 0);
      expect(triggerValue(10, cfg), 0); // 0.039 < 0.05
      expect(triggerValue(255, cfg), 1);
      // Halfway between the dead zone and full scale.
      final mid = ((0.05 + 1) / 2 * 255).round();
      expect(triggerValue(mid, cfg), closeTo(0.5, 0.01));
      // A trigger that tops out early still reaches 1.
      expect(triggerValue(200, cfg.copyWith(triggerFullScale: 200)), 1);
      expect(triggerValue(255, cfg.copyWith(triggerFullScale: 200)), 1);
    });

    test('L2/R2 press at the threshold', () {
      final c = cfg.copyWith(triggerDeadZone: 0, triggerPressThreshold: 0.5);
      expect(mapGamepad(hand(trigger: 127), null, c).buttons, isEmpty);
      final s = mapGamepad(hand(trigger: 128), hand(trigger: 255), c);
      expect(s.buttons, {GamepadButton.l2, GamepadButton.r2});
      expect(s.leftTrigger, closeTo(128 / 255, 1e-9));
      expect(s.rightTrigger, 1);
    });
  });

  group('trackpad', () {
    test('face buttons by dominant axis, y up', () {
      Set<GamepadButton> at(double x, double y) =>
          trackpadButtons(x, y, TrackpadRole.faceButtons, 0.3);
      expect(at(0, 0.9), {GamepadButton.y});
      expect(at(0, -0.9), {GamepadButton.a});
      expect(at(0.9, 0.2), {GamepadButton.b});
      expect(at(-0.9, -0.2), {GamepadButton.x});
      expect(at(0.1, 0.1), isEmpty); // inside the centre
    });

    test('d-pad has 8 sectors', () {
      Set<GamepadButton> at(double a) => trackpadButtons(
        0.9 * math.cos(a * deg),
        0.9 * math.sin(a * deg),
        TrackpadRole.dpad,
        0.3,
      );
      expect(at(90), {GamepadButton.dpadUp});
      expect(at(45), {GamepadButton.dpadUp, GamepadButton.dpadRight});
      expect(at(0), {GamepadButton.dpadRight});
      expect(at(-60), {GamepadButton.dpadDown, GamepadButton.dpadRight});
      expect(at(-80), {GamepadButton.dpadDown});
      expect(at(180), {GamepadButton.dpadLeft});
    });

    test('needs click and touch; roles follow the config', () {
      // Touch without click presses nothing.
      expect(
        mapGamepad(
          null,
          hand(buttons: wmrBtnTrackpadTouch, trackpad: const [0, -0.9]),
          cfg,
        ).buttons,
        isEmpty,
      );
      final s = mapGamepad(
        hand(buttons: click, trackpad: const [0, 0.9]),
        hand(buttons: click, trackpad: const [0, -0.9]),
        cfg,
      );
      expect(s.buttons, {GamepadButton.dpadUp, GamepadButton.a});
      final swapped = mapGamepad(
        hand(buttons: click, trackpad: const [0, 0.9]),
        hand(buttons: click, trackpad: const [0, -0.9]),
        cfg.copyWith(leftTrackpad: TrackpadRole.none, invertTrackpadY: true),
      );
      expect(swapped.buttons, {GamepadButton.y});
    });
  });

  group('tilt', () {
    const tilt = TiltConfig(
      target: TiltTarget.rightStick,
      hand: 1,
      maxDegrees: 30,
      deadZoneDegrees: 0,
    );

    test('lean right and tip away give +x and +y, saturating', () {
      // Leaning the top right: negative roll about Z (toward the user).
      expect(
        tiltStick(quaternionFromEuler(0, 0, -15 * deg), tilt)[0],
        closeTo(0.5, 1e-6),
      );
      expect(tiltStick(quaternionFromEuler(0, 0, -60 * deg), tilt)[0], 1);
      // Tipping the top away: negative pitch about X (right).
      expect(
        tiltStick(quaternionFromEuler(0, -15 * deg, 0), tilt)[1],
        closeTo(0.5, 1e-6),
      );
      final inv = tiltStick(
        quaternionFromEuler(0, -15 * deg, -15 * deg),
        tilt.copyWith(invertX: true, invertY: true),
      );
      expect(inv[0], closeTo(-0.5, 1e-6));
      expect(inv[1], closeTo(-0.5, 1e-6));
    });

    test('yaw is ignored and the dead zone is removed', () {
      final yawed = tiltStick(quaternionFromEuler(1.2, 0, 0), tilt);
      expect(yawed[0], closeTo(0, 1e-9));
      expect(yawed[1], closeTo(0, 1e-9));
      final dz = tilt.copyWith(deadZoneDegrees: 10);
      expect(tiltStick(quaternionFromEuler(0, 0, -8 * deg), dz)[0], 0);
      expect(
        tiltStick(quaternionFromEuler(0, 0, -20 * deg), dz)[0],
        closeTo(0.5, 1e-6),
      );
    });

    test('drives the chosen stick; the larger magnitude wins', () {
      final right = hand(
        stick: const [-0.2, 0.9],
        orientation: quaternionFromEuler(0, 0, -15 * deg),
      );
      final s = mapGamepad(null, right, const GamepadConfig(tilt: tilt));
      expect(s.rightStick[0], closeTo(0.5, 1e-6)); // tilt beats -0.2
      expect(s.rightStick[1], 0.9); // stick beats 0
      expect(s.leftStick, [0, 0]);
      // Tilt from a hand without orientation, or switched off, does nothing.
      expect(
        mapGamepad(
          null,
          hand(stick: const [-0.2, 0.9]),
          const GamepadConfig(tilt: tilt),
        ).rightStick,
        [-0.2, 0.9],
      );
      expect(mapGamepad(null, right, cfg).rightStick, [-0.2, 0.9]);
    });
  });

  test('HandInput.fromSample scales the trackpad and keeps the stick', () {
    const r = DecodedRecord(
      hand: 1,
      sequence: 1,
      rxTimeUs: 0,
      deviceTicks: 0,
      gyro: [0, 0, 0],
      accel: [0, 0, 9.8],
      buttons: wmrBtnMenu,
      trackpad: [32767, -16384],
      trigger: 200,
    );
    final q = vm.Quaternion.identity();
    final input = HandInput.fromSample(
      DecodedSample(
        record: r,
        receivedAtUs: 0,
        step: const TickStep(TickStepKind.baseline),
        orientation: q,
        fused: false,
        stick: const [0.1, -0.2],
      ),
    );
    expect(input.buttons, wmrBtnMenu);
    expect(input.trigger, 200);
    expect(input.stick, [0.1, -0.2]);
    expect(input.trackpad[0], 1);
    expect(input.trackpad[1], closeTo(-0.5, 1e-4));
    expect(input.orientation, same(q));
  });

  test('config equality covers every field', () {
    expect(cfg, const GamepadConfig());
    expect(cfg == cfg.copyWith(triggerFullScale: 200), isFalse);
    expect(cfg == cfg.copyWith(tilt: const TiltConfig(invertY: true)), isFalse);
    expect(cfg.hashCode, const GamepadConfig().hashCode);
  });
}
