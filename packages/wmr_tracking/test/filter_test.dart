import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

final _grip = Vector3(0, -0.02, -0.06);
const _hz30 = 33333333;

TrackingFrame _handFrame(
  int timeNs,
  Vector3 palm, {
  Pose? head,
  TrackedHand hand = TrackedHand.right,
}) {
  final pose = Pose(translation: palm, rotation: Quaternion.identity());
  final handPose = HandPose(
    hand: hand,
    palm: TrackedPose(pose: pose),
    joints: {HandJoint.palm: TrackedPose(pose: pose)},
  );
  return TrackingFrame(
    timeNs: timeNs,
    hostTimeNs: timeNs,
    head: head == null ? null : TrackedPose(pose: head),
    leftHand: hand == TrackedHand.left ? handPose : null,
    rightHand: hand == TrackedHand.right ? handPose : null,
  );
}

/// Palm position that makes the fuser's default grip offset land on [target].
Vector3 _palmFor(Vector3 target) => target - _grip;

double _gaussian(math.Random random) {
  final u1 = 1 - random.nextDouble();
  final u2 = random.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

double _rmse(List<Vector3> values, Vector3 truth) {
  final sum = values.fold<double>(
    0,
    (acc, value) => acc + (value - truth).length * (value - truth).length,
  );
  return math.sqrt(sum / values.length);
}

void main() {
  group('OneEuroFilter', () {
    test('passes the first sample through and rejects bad input', () {
      final filter = OneEuroFilter();
      final sample = Vector3(0.1, 1.2, -0.3);

      expect(filter.filter(sample, 1000), sample);
      expect(filter.hasValue, isTrue);
      expect(() => filter.filter(sample, 0), throwsA(isA<ArgumentError>()));
      expect(
        () => filter.filter(Vector3(double.nan, 0, 0), 2000),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('resets after a gap longer than maxDt', () {
      final filter = OneEuroFilter();
      filter.filter(Vector3.zero(), 1000);
      filter.filter(Vector3(0.1, 0, 0), 2000);

      final afterGap = filter.filter(
        Vector3(1, 2, 3),
        2000 + const Duration(milliseconds: 150).inMicroseconds * 1000,
      );

      expect(afterGap, Vector3(1, 2, 3));
    });

    test('a duplicate timestamp keeps the previous state', () {
      final filter = OneEuroFilter();
      filter.filter(Vector3.zero(), 1000);
      final first = filter.filter(Vector3(0.1, 0, 0), 2000);
      final duplicate = filter.filter(Vector3(9, 9, 9), 2000);

      expect(duplicate, first);
    });

    test('is deterministic for the same samples', () {
      List<Vector3> run() {
        final filter = OneEuroFilter();
        return [
          for (var i = 0; i < 120; i++)
            filter.filter(
              Vector3(i * 0.001, math.sin(i / 5) * 0.01, 0),
              (i + 1) * _hz30,
            ),
        ];
      }

      expect(run(), run());
    });
  });

  test('filter_static: 5 mm noise at 30 Hz is reduced without drift', () {
    final truth = Vector3(0.3, 1.2, -0.4);
    final random = math.Random(42);
    final fuser = SixDofFuser();
    final raw = <Vector3>[];
    final filtered = <Vector3>[];
    final orientation = Quaternion(0.1, 0.2, 0.3, math.sqrt(0.86));

    for (var i = 0; i < 300; i++) {
      final timeNs = (i + 1) * _hz30;
      final palm =
          _palmFor(truth) +
          Vector3(
            _gaussian(random) * 0.005,
            _gaussian(random) * 0.005,
            _gaussian(random) * 0.005,
          );
      fuser.onTrackingFrame(_handFrame(timeNs, palm));
      final pose = fuser.update(
        hand: TrackedHand.right,
        orientation: orientation,
        hostTimeNs: timeNs,
      );
      expect(pose.orientation.x, orientation.normalized().x);
      expect(pose.orientation.y, orientation.normalized().y);
      expect(pose.orientation.z, orientation.normalized().z);
      expect(pose.orientation.w, orientation.normalized().w);
      if (i >= 30) {
        raw.add(palm + _grip);
        filtered.add(pose.position!);
      }
    }

    final rawRmse = _rmse(raw, truth);
    final filteredRmse = _rmse(filtered, truth);
    final meanError =
        filtered.fold(Vector3.zero(), (a, p) => a + (p - truth)) /
        filtered.length.toDouble();

    expect(filteredRmse, lessThan(rawRmse));
    expect(meanError.length, lessThan(0.002));
  });

  for (final hz in [30, 60, 90]) {
    test('filter_ramp: 0.5 m/s at ${hz}Hz stays under 150 ms lag', () {
      const speed = 0.5;
      final dtNs = (1000000000 / hz).round();
      final random = math.Random(7 + hz);
      final fuser = SixDofFuser();
      final filtered = <double>[];
      final truth = <double>[];
      var timeNs = 1000000000;
      final gap = (0.002 * 1000000000).round();

      for (var i = 0; i < hz * 5; i++) {
        final jitter = ((random.nextDouble() * 2 - 1) * gap).round();
        timeNs += dtNs + jitter;
        final t = (timeNs - 1000000000) / 1000000000;
        final x = speed * t;
        final target = Vector3(x, 1.2, -0.4);
        fuser.onTrackingFrame(_handFrame(timeNs, _palmFor(target)));
        final pose = fuser.update(
          hand: TrackedHand.right,
          orientation: Quaternion.identity(),
          hostTimeNs: timeNs,
        );
        if (t >= 2) {
          filtered.add(pose.position!.x);
          truth.add(x);
        }
      }

      final lag = [
        for (var i = 0; i < filtered.length; i++)
          (truth[i] - filtered[i]) / speed,
      ];
      final meanLag = lag.reduce((a, b) => a + b) / lag.length.toDouble();

      expect(filtered.every((value) => value.isFinite), isTrue);
      expect(meanLag, lessThan(0.150));
      expect(meanLag, greaterThan(0));
    });
  }

  test('filter_gap: a 150 ms dropout releases, then resets the filter', () {
    final fuser = SixDofFuser();
    final start = 1000000000;
    final startPalm = _palmFor(Vector3(0.2, 1.1, -0.4));
    fuser.onTrackingFrame(_handFrame(start, startPalm));
    final before = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: start,
    );
    expect(before.source, ControllerPoseSource.handAnchor);

    final resumed =
        start + const Duration(milliseconds: 150).inMicroseconds * 1000;
    final stale = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: resumed,
    );
    expect(stale.source, ControllerPoseSource.orientationOnly);
    expect(stale.position, isNull);
    expect(stale.confidence, TrackingConfidence.none);

    final steppedPalm = _palmFor(Vector3(0.3, 1.1, -0.4));
    fuser.onTrackingFrame(_handFrame(resumed, steppedPalm));
    final after = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: resumed,
    );

    expect(after.source, ControllerPoseSource.handAnchor);
    expect(after.confidence, TrackingConfidence.high);
    expect(after.position, Vector3(0.3, 1.1, -0.4));
    expect(after.frameAgeNs, 0);
  });

  test('filter does not smooth across a source transition', () {
    final fuser = SixDofFuser();
    final start = 1000000000;
    fuser.onTrackingFrame(_handFrame(start, _palmFor(Vector3(0.2, 1.1, -0.4))));
    fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: start,
    );

    fuser.onTrackingFrame(
      TrackingFrame(
        timeNs: start + _hz30,
        hostTimeNs: start + _hz30,
        controllers: {
          TrackedHand.right: TrackedPose(
            pose: Pose(
              translation: Vector3(0.8, 1.3, -0.5),
              rotation: Quaternion.identity(),
            ),
          ),
        },
      ),
    );
    final runtime = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: start + _hz30,
    );
    expect(runtime.source, ControllerPoseSource.runtimeController);
    expect(runtime.position, Vector3(0.8, 1.3, -0.5));

    fuser.onTrackingFrame(
      _handFrame(start + 2 * _hz30, _palmFor(Vector3(0.3, 1.1, -0.4))),
    );
    final hand = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: start + 2 * _hz30,
    );
    expect(hand.source, ControllerPoseSource.handAnchor);
    expect(hand.position, Vector3(0.3, 1.1, -0.4));
  });

  test('a non-finite anchor pose is rejected', () {
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(_handFrame(1000, Vector3(double.nan, 1.1, -0.4)));
    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    expect(pose.source, ControllerPoseSource.orientationOnly);
    expect(pose.position, isNull);
    expect(pose.confidence, TrackingConfidence.none);
  });

  test('a non-positive sample timestamp is rejected', () {
    final fuser = SixDofFuser();
    expect(
      () => fuser.update(
        hand: TrackedHand.right,
        orientation: Quaternion.identity(),
        hostTimeNs: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  group('anchor clock (ONY-502)', () {
    test('filters once per anchor sample, not per controller tick', () {
      const anchorDt = 33333333;
      const tickDt = 5555555;
      final fuser = SixDofFuser();
      final direct = const PoseFilterConfig().createFilter();
      final random = math.Random(11);
      var frameTime = 1000000000;

      for (var i = 0; i < 90; i++) {
        final target =
            Vector3(0.2 + i * 0.0005, -0.25, -0.35) +
            Vector3(
              _gaussian(random) * 0.0005,
              _gaussian(random) * 0.0005,
              _gaussian(random) * 0.0005,
            );
        fuser.onTrackingFrame(_handFrame(frameTime, _palmFor(target)));
        final pose = fuser.update(
          hand: TrackedHand.right,
          orientation: Quaternion.identity(),
          hostTimeNs: frameTime,
        );
        final reference = direct.filter(target, frameTime);
        expect((pose.position! - reference).length, lessThan(1e-12));

        for (var tick = 1; tick <= 5; tick++) {
          final held = fuser.update(
            hand: TrackedHand.right,
            orientation: Quaternion.identity(),
            hostTimeNs: frameTime + tick * tickDt,
          );
          expect((held.position! - pose.position!).length, lessThan(1e-12));
        }
        frameTime += anchorDt;
      }
    });

    test('a long anchor interval uses the anchor timestamp', () {
      final fuser = SixDofFuser();
      final direct = const PoseFilterConfig().createFilter();
      const start = 1000000000;
      const gap = 90000000;
      final first = Vector3(0.2, -0.25, -0.35);
      final second = Vector3(0.21, -0.25, -0.35);

      fuser.onTrackingFrame(_handFrame(start, _palmFor(first)));
      fuser.update(
        hand: TrackedHand.right,
        orientation: Quaternion.identity(),
        hostTimeNs: start,
      );
      direct.filter(first, start);

      for (var tick = 1; tick <= 17; tick++) {
        fuser.update(
          hand: TrackedHand.right,
          orientation: Quaternion.identity(),
          hostTimeNs: start + tick * 5000000,
        );
      }

      fuser.onTrackingFrame(_handFrame(start + gap, _palmFor(second)));
      final after = fuser.update(
        hand: TrackedHand.right,
        orientation: Quaternion.identity(),
        hostTimeNs: start + gap,
      );
      final reference = direct.filter(second, start + gap);

      expect((after.position! - reference).length, lessThan(1e-12));
    });
  });
}
