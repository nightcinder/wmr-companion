import 'dart:io';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

String _read(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  test('Android XR fixture decodes 26 OpenXR-named joints', () {
    const codec = TrackingFrameCodec();
    final frame = codec.decodeString(_read('android_xr_26_joint_frame.json'));

    expect(frame.timeNs, 1700000000000000);
    expect(frame.head, isNotNull);
    expect(frame.head!.confidence, TrackingConfidence.high);

    final hand = frame.rightHand!;
    expect(hand.hand, TrackedHand.right);
    expect(hand.joints, hasLength(26));
    expect(
      hand.joints.keys,
      containsAll([
        HandJoint.wrist,
        HandJoint.palm,
        HandJoint.thumbMetacarpal,
        HandJoint.thumbTip,
        HandJoint.indexMetacarpal,
        HandJoint.indexTip,
        HandJoint.middleTip,
        HandJoint.ringTip,
        HandJoint.littleTip,
      ]),
    );
    expect(
      hand.joints[HandJoint.palm]!.pose.translation,
      Vector3(0, 1.21, -0.36),
    );
    expect(hand.palmPose, isNotNull);
  });

  test(
    'fixture palm anchors the controller through the default grip offset',
    () {
      const codec = TrackingFrameCodec();
      final frame = codec.decodeString(_read('android_xr_26_joint_frame.json'));
      final fuser = SixDofFuser();
      fuser.onTrackingFrame(frame.withHostTime(frame.timeNs));

      final pose = fuser.update(
        hand: TrackedHand.right,
        orientation: Quaternion.identity(),
        hostTimeNs: frame.timeNs,
      );

      expect(pose.source, ControllerPoseSource.handAnchor);
      expect(pose.confidence, TrackingConfidence.high);
      // palm (0, 1.21, -0.36) + default grip (0, -0.02, -0.06)
      expect(pose.position, Vector3(0, 1.19, -0.42));
    },
  );

  test('fixture grip anchor wins over the palm', () {
    const codec = TrackingFrameCodec();
    final frame = codec.decodeString(
      _read('android_xr_26_joint_grip_frame.json'),
    );
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(frame.withHostTime(frame.timeNs));

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: frame.timeNs,
    );

    expect(pose.source, ControllerPoseSource.handAnchor);
    // The grip pose is the anchor; the default grip offset still applies.
    expect(pose.position, Vector3(0.03, 1.15, -0.47));
  });
}
