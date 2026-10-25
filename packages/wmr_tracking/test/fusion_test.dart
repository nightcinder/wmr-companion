import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

TrackingFrame _frame(
  int ns, {
  Pose? head,
  HandPose? left,
  HandPose? right,
  Map<TrackedHand, Pose> controllers = const {},
}) => TrackingFrame(
  timeNs: ns,
  hostTimeNs: ns,
  head: head == null ? null : TrackedPose(pose: head),
  leftHand: left,
  rightHand: right,
  controllers: {
    for (final entry in controllers.entries)
      entry.key: TrackedPose(pose: entry.value),
  },
);

HandPose _hand(
  TrackedHand hand,
  Pose palm, {
  TrackingConfidence confidence = TrackingConfidence.high,
}) => HandPose(
  hand: hand,
  palm: TrackedPose(pose: palm, confidence: confidence),
);

void main() {
  test('a runtime controller pose wins over a hand anchor', () {
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(
      _frame(
        1000,
        right: _hand(
          TrackedHand.right,
          Pose(
            translation: Vector3(0.2, 1.2, -0.4),
            rotation: Quaternion.identity(),
          ),
        ),
        controllers: {
          TrackedHand.right: Pose(
            translation: Vector3(1, 2, 3),
            rotation: Quaternion.identity(),
          ),
        },
      ),
    );

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    expect(pose.source, ControllerPoseSource.runtimeController);
    expect(pose.position, _vector(1, 2, 3));
    expect(pose.confidence, TrackingConfidence.high);
  });

  test(
    'a palm anchor plus the default grip offset positions the controller',
    () {
      final fuser = SixDofFuser();
      fuser.onTrackingFrame(
        _frame(
          1000,
          right: _hand(
            TrackedHand.right,
            Pose(
              translation: Vector3(0.2, 1.2, -0.4),
              rotation: Quaternion.identity(),
            ),
          ),
        ),
      );

      final pose = fuser.update(
        hand: TrackedHand.right,
        orientation: Quaternion.identity(),
        hostTimeNs: 1000,
      );

      expect(pose.source, ControllerPoseSource.handAnchor);
      expect(pose.hasPosition, isTrue);
      expect(pose.position, _vector(0.2, 1.18, -0.46));
      expect(pose.frameAgeNs, 0);
    },
  );

  test('a head pose alone uses the low-confidence head-relative fallback', () {
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(
      _frame(
        1000,
        head: Pose(
          translation: Vector3(0, 1.6, 0),
          rotation: Quaternion.identity(),
        ),
      ),
    );

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    expect(pose.source, ControllerPoseSource.headRelative);
    expect(pose.confidence, TrackingConfidence.low);
    expect(pose.position, _vector(0.2, 1.35, -0.3));
  });

  test(
    'a head-relative fallback does not bias the first anchored position',
    () {
      final fuser = SixDofFuser();
      fuser.onTrackingFrame(
        _frame(
          1000,
          head: Pose(
            translation: Vector3(0, 1.6, 0),
            rotation: Quaternion.identity(),
          ),
        ),
      );
      final fallback = fuser.update(
        hand: TrackedHand.right,
        orientation: Quaternion.identity(),
        hostTimeNs: 1000,
      );
      expect(fallback.source, ControllerPoseSource.headRelative);
      expect(fallback.position, _vector(0.2, 1.35, -0.3));

      fuser.onTrackingFrame(
        _frame(
          2000,
          right: _hand(
            TrackedHand.right,
            Pose(
              translation: Vector3(0.5, 1.2, -0.4),
              rotation: Quaternion.identity(),
            ),
          ),
        ),
      );
      final anchored = fuser.update(
        hand: TrackedHand.right,
        orientation: Quaternion.identity(),
        hostTimeNs: 2000,
      );

      expect(anchored.source, ControllerPoseSource.handAnchor);
      expect(anchored.position, _vector(0.5, 1.18, -0.46));
    },
  );

  test('the learned head-local offset follows a moved head', () {
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(
      _frame(
        1000,
        head: Pose(
          translation: Vector3(0, 1.6, 0),
          rotation: Quaternion.identity(),
        ),
        right: _hand(
          TrackedHand.right,
          Pose(
            translation: Vector3(0.3, 1.1, -0.5),
            rotation: Quaternion.identity(),
          ),
        ),
      ),
    );
    fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    fuser.onTrackingFrame(
      _frame(
        2000,
        head: Pose(
          translation: Vector3(0, 1.7, 0),
          rotation: Quaternion.identity(),
        ),
      ),
    );
    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 2000,
    );

    expect(pose.source, ControllerPoseSource.headRelative);
    expect(pose.position, _vector(0.3, 1.18, -0.56));
  });

  test('a head appearing after a hand anchor learns the last position', () {
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(
      _frame(
        1000,
        right: _hand(
          TrackedHand.right,
          Pose(
            translation: Vector3(0.3, 1.1, -0.5),
            rotation: Quaternion.identity(),
          ),
        ),
      ),
    );
    fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    fuser.onTrackingFrame(
      _frame(
        2000,
        head: Pose(
          translation: Vector3(0, 1.7, 0),
          rotation: Quaternion.identity(),
        ),
      ),
    );
    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 2000,
    );

    expect(pose.source, ControllerPoseSource.headRelative);
    expect(pose.position, _vector(0.3, 1.08, -0.56));
  });

  test('a stale frame releases the position instead of pinning it', () {
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(
      _frame(
        1000,
        head: Pose(
          translation: Vector3(0, 1.6, 0),
          rotation: Quaternion.identity(),
        ),
      ),
    );

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000000000,
    );

    expect(pose.source, ControllerPoseSource.orientationOnly);
    expect(pose.position, isNull);
    expect(pose.confidence, TrackingConfidence.none);
  });

  test('the newest frame at or before the sample is used', () {
    final fuser = SixDofFuser(
      config: const SixDofFusionConfig(lateTolerance: Duration.zero),
    );
    fuser.onTrackingFrame(
      _frame(
        1000,
        right: _hand(
          TrackedHand.right,
          Pose(translation: Vector3(0, 1, 0), rotation: Quaternion.identity()),
        ),
      ),
    );
    fuser.onTrackingFrame(
      _frame(
        2000,
        right: _hand(
          TrackedHand.right,
          Pose(translation: Vector3(1, 1, 0), rotation: Quaternion.identity()),
        ),
      ),
    );

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1500,
    );

    expect(pose.position!.x, 0);
    expect(pose.frameAgeNs, 500);
  });

  test('a slightly early frame is accepted within the late tolerance', () {
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(
      _frame(
        1002,
        right: _hand(
          TrackedHand.right,
          Pose(translation: Vector3(1, 1, 0), rotation: Quaternion.identity()),
        ),
      ),
    );

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    expect(pose.hasPosition, isTrue);
    expect(pose.frameAgeNs, -2);
  });

  test('position smoothing moves toward a runtime controller pose', () {
    final fuser = SixDofFuser(
      config: const SixDofFusionConfig(positionSmoothing: 0.5),
    );
    fuser.onTrackingFrame(
      _frame(
        1000,
        controllers: {
          TrackedHand.right: Pose(
            translation: Vector3(0.2, 1, 0),
            rotation: Quaternion.identity(),
          ),
        },
      ),
    );
    fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    fuser.onTrackingFrame(
      _frame(
        2000,
        controllers: {
          TrackedHand.right: Pose(
            translation: Vector3(0.6, 1, 0),
            rotation: Quaternion.identity(),
          ),
        },
      ),
    );
    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 2000,
    );

    expect(pose.position!.x, closeTo(0.4, 1e-9));
  });

  test('grip calibration maps a palm pose onto a known controller pose', () {
    final fuser = SixDofFuser();
    fuser.calibrateGrip(
      hand: TrackedHand.right,
      palm: Pose(translation: Vector3.zero(), rotation: Quaternion.identity()),
      controller: Pose(
        translation: Vector3(0.1, 0, 0),
        rotation: Quaternion.identity(),
      ),
    );
    fuser.onTrackingFrame(
      _frame(
        1000,
        right: _hand(
          TrackedHand.right,
          Pose(translation: Vector3(0, 1, 0), rotation: Quaternion.identity()),
        ),
      ),
    );

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    expect(pose.position, _vector(0.1, 1, 0));
  });

  test('reset clears frames and learned offsets but keeps calibration', () {
    final fuser = SixDofFuser();
    fuser.calibrateGrip(
      hand: TrackedHand.right,
      palm: Pose(translation: Vector3.zero(), rotation: Quaternion.identity()),
      controller: Pose(
        translation: Vector3(0.1, 0, 0),
        rotation: Quaternion.identity(),
      ),
    );
    fuser.onTrackingFrame(
      _frame(
        1000,
        right: _hand(
          TrackedHand.right,
          Pose(translation: Vector3(0, 1, 0), rotation: Quaternion.identity()),
        ),
      ),
    );
    fuser.reset();

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: 1000,
    );

    expect(pose.source, ControllerPoseSource.orientationOnly);
    expect(fuser.gripOffset(TrackedHand.right).translation.x, 0.1);
  });
}

Matcher _vector(double x, double y, double z) => predicate<Vector3>(
  (actual) =>
      (actual.x - x).abs() < 1e-9 &&
      (actual.y - y).abs() < 1e-9 &&
      (actual.z - z).abs() < 1e-9,
  'is <$x, $y, $z>',
);
