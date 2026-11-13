import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/domain/tick_timer.dart';

import 'sim.dart';

GamepadState _noInput() => GamepadState(
  buttons: const {},
  leftStick: const [0, 0],
  rightStick: const [0, 0],
  leftTrigger: 0,
  rightTrigger: 0,
);

DecodedSample _sample({vm.Vector3? angularVelocity}) => DecodedSample(
  record: record(ticks: 0),
  receivedAtUs: 0,
  step: const TickStep(TickStepKind.step, dtTicks: 1000, dtSeconds: 0.0001),
  orientation: vm.Quaternion.identity(),
  fused: true,
  angularVelocity: angularVelocity,
);

void main() {
  group('pipeline view-frame angular velocity', () {
    test('a baseline sample has no angular velocity', () {
      final p = HandPipeline();
      final s = p.add(record(ticks: 0), 0);
      expect(s.fused, isFalse);
      expect(s.angularVelocity, isNull);
    });

    test('a known raw gyro maps to the expected view-frame rate', () {
      // Default mapping: view = (-g[1], g[0], g[2]). No bias before the
      // stationary window completes, so the view rate is the mapped raw rate.
      final p = HandPipeline();
      p.add(record(ticks: 0), 0);
      final s = p.add(
        record(ticks: nominalPeriodTicks, gyro: const [0.1, 0.2, 0.3]),
        0,
      );
      expect(s.fused, isTrue);
      final w = s.angularVelocity!;
      expect(w.x, closeTo(-0.2, 1e-9));
      expect(w.y, closeTo(0.1, 1e-9));
      expect(w.z, closeTo(0.3, 1e-9));
    });

    test('a zero raw gyro stays zero', () {
      final p = HandPipeline();
      p.add(record(ticks: 0), 0);
      final s = p.add(record(ticks: nominalPeriodTicks), 0);
      final w = s.angularVelocity!;
      expect([w.x, w.y, w.z], everyElement(0));
    });

    test('a non-finite gyro reading gives no angular velocity', () {
      final p = HandPipeline();
      p.add(record(ticks: 0), 0);
      final s = p.add(
        record(ticks: nominalPeriodTicks, gyro: const [double.nan, 0, 0]),
        0,
      );
      expect(s.angularVelocity, isNull);
    });
  });

  group('DroidDeck hand mapping', () {
    test('no angular velocity maps to zeros', () {
      final hand = DroidDeckXrHand.fromPipeline(_sample(), _noInput());
      expect(hand.angularVelocity, [0, 0, 0]);
    });

    test('non-finite components are sent as zero', () {
      final hand = DroidDeckXrHand.fromPipeline(
        _sample(angularVelocity: vm.Vector3(double.infinity, 1, double.nan)),
        _noInput(),
      );
      expect(hand.angularVelocity, [0, 1, 0]);
      expect(hand.angularVelocity.every((v) => v.isFinite), isTrue);
    });

    test('a finite view-frame rate is passed through unrotated', () {
      final hand = DroidDeckXrHand.fromPipeline(
        _sample(angularVelocity: vm.Vector3(-0.2, 0.1, 0.3)),
        _noInput(),
      );
      expect(hand.angularVelocity[0], closeTo(-0.2, 1e-12));
      expect(hand.angularVelocity[1], closeTo(0.1, 1e-12));
      expect(hand.angularVelocity[2], closeTo(0.3, 1e-12));
    });
  });

  group('DroidDeck packet', () {
    test('angular velocity is written at hand offset 56', () {
      final bytes = encodeDroidDeckXrInput(
        sequence: 1,
        timeNs: 1,
        left: const DroidDeckXrHand(
          connected: true,
          angularVelocity: [0.5, -1.25, 2],
        ),
        right: const DroidDeckXrHand(
          connected: true,
          angularVelocity: [-3, 0, 0.75],
        ),
      );
      final d = ByteData.sublistView(bytes);
      // Left hand starts at 40, right at 152; angular velocity at +56.
      expect(d.getFloat32(40 + 56, Endian.little), closeTo(0.5, 1e-6));
      expect(d.getFloat32(40 + 60, Endian.little), closeTo(-1.25, 1e-6));
      expect(d.getFloat32(40 + 64, Endian.little), closeTo(2, 1e-6));
      expect(d.getFloat32(152 + 56, Endian.little), closeTo(-3, 1e-6));
      expect(d.getFloat32(152 + 60, Endian.little), 0);
      expect(d.getFloat32(152 + 64, Endian.little), closeTo(0.75, 1e-6));
    });

    test('a non-finite value in the hand is written as zero', () {
      final bytes = encodeDroidDeckXrInput(
        sequence: 1,
        timeNs: 1,
        left: DroidDeckXrHand(
          connected: true,
          angularVelocity: const [double.nan, 1, 0],
        ),
      );
      final d = ByteData.sublistView(bytes);
      expect(d.getFloat32(40 + 56, Endian.little), 0);
      expect(d.getFloat32(40 + 60, Endian.little), closeTo(1, 1e-6));
    });
  });
}
