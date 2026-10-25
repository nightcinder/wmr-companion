import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

void main() {
  test('a frame with a head, a hand and a controller round-trips', () {
    final frame = TrackingFrame(
      timeNs: 123456789,
      hostTimeNs: 223456789,
      head: TrackedPose(
        pose: Pose(
          translation: Vector3(0, 1.6, 0),
          rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.3),
        ),
      ),
      rightHand: HandPose(
        hand: TrackedHand.right,
        joints: {
          HandJoint.wrist: TrackedPose(
            pose: Pose(
              translation: Vector3(0.2, 1.2, -0.4),
              rotation: Quaternion.identity(),
            ),
          ),
        },
        grip: TrackedPose(
          pose: Pose(
            translation: Vector3(0.2, 1.18, -0.46),
            rotation: Quaternion.identity(),
          ),
          confidence: TrackingConfidence.medium,
        ),
      ),
      controllers: {
        TrackedHand.left: TrackedPose(
          pose: Pose(
            translation: Vector3(-0.2, 1.2, -0.4),
            rotation: Quaternion.identity(),
          ),
        ),
      },
    );

    const codec = TrackingFrameCodec();
    final decoded = codec.decodeString(codec.encodeToString(frame));

    expect(decoded.timeNs, frame.timeNs);
    expect(decoded.hostTimeNs, frame.hostTimeNs);
    expect(decoded.head!.pose.translation, frame.head!.pose.translation);
    expect(decoded.rightHand!.hand, TrackedHand.right);
    expect(
      decoded.rightHand!.joints[HandJoint.wrist]!.pose.translation,
      Vector3(0.2, 1.2, -0.4),
    );
    expect(decoded.rightHand!.grip!.confidence, TrackingConfidence.medium);
    expect(decoded.controllers[TrackedHand.left], isNotNull);
  });

  test('a minimal frame decodes and applies a host timestamp', () {
    const codec = TrackingFrameCodec();

    final frame = codec.decode({
      'v': 1,
      'time_ns': 42,
      'head': {
        'pose': {
          't': [0, 1.5, 0],
          'q': [0, 0, 0, 1],
        },
      },
    }, hostTimeNs: 9000);

    expect(frame.timeNs, 42);
    expect(frame.fusionTimeNs, 9000);
    expect(frame.head!.pose.translation.y, 1.5);
    expect(frame.leftHand, isNull);
  });

  test('an unknown frame version is rejected', () {
    const codec = TrackingFrameCodec();

    expect(() => codec.decode({'v': 2, 'time_ns': 1}), throwsFormatException);
  });

  test('unknown joints are ignored for forward compatibility', () {
    const codec = TrackingFrameCodec();

    final frame = codec.decode({
      'v': 1,
      'time_ns': 1,
      'hands': {
        'left': {
          'hand': 'left',
          'joints': {
            'wrist': {
              'pose': {
                't': [0, 0, 0],
                'q': [0, 0, 0, 1],
              },
            },
            'future_joint': {
              'pose': {
                't': [1, 1, 1],
                'q': [0, 0, 0, 1],
              },
            },
          },
        },
      },
    });

    expect(frame.leftHand!.joints.keys, [HandJoint.wrist]);
  });
}
