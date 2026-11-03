import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

String _read(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  test('frame_conversion: Unity p=(1,2,3), q=(qx,qy,qz,qw) maps to OpenXR '
      '(1,2,-3), (-qx,-qy,qz,qw) within 1e-6 and round-trips', () {
    final q = Quaternion(0.1, 0.2, 0.3, 0.9273618495495704).normalized();
    final unity = Pose(translation: Vector3(1, 2, 3), rotation: q);

    final openXr = unityToOpenXrPose(unity);

    expect(openXr.translation.x, closeTo(1.0, 1e-6));
    expect(openXr.translation.y, closeTo(2.0, 1e-6));
    expect(openXr.translation.z, closeTo(-3.0, 1e-6));
    expect(openXr.rotation.x, closeTo(-q.x, 1e-6));
    expect(openXr.rotation.y, closeTo(-q.y, 1e-6));
    expect(openXr.rotation.z, closeTo(q.z, 1e-6));
    expect(openXr.rotation.w, closeTo(q.w, 1e-6));

    final roundTrip = openXrToUnityPose(openXr);
    expect(roundTrip.translation.x, closeTo(unity.translation.x, 1e-6));
    expect(roundTrip.translation.y, closeTo(unity.translation.y, 1e-6));
    expect(roundTrip.translation.z, closeTo(unity.translation.z, 1e-6));
    expect(roundTrip.rotation.x, closeTo(unity.rotation.x, 1e-6));
    expect(roundTrip.rotation.y, closeTo(unity.rotation.y, 1e-6));
    expect(roundTrip.rotation.z, closeTo(unity.rotation.z, 1e-6));
    expect(roundTrip.rotation.w, closeTo(unity.rotation.w, 1e-6));
  });

  test('XREAL 26-joint Unity fixture decodes all 26 XRHandJointID joints and '
      'converts Unity coordinates to OpenXR', () {
    const codec = UnityRelayFrameCodec();
    final frame = codec.decodeString(_read('xreal_26_joint_unity_frame.json'));

    expect(frame.timeNs, 1900000000000000);
    expect(frame.head, isNotNull);
    expect(frame.head!.confidence, TrackingConfidence.high);
    expect(frame.head!.pose.translation.x, closeTo(0.0, 1e-6));
    expect(frame.head!.pose.translation.y, closeTo(1.62, 1e-6));
    expect(frame.head!.pose.translation.z, closeTo(-0.08, 1e-6));
    expect(frame.head!.pose.rotation.x, closeTo(-0.05, 1e-6));
    expect(frame.head!.pose.rotation.y, closeTo(0.10, 1e-6));
    expect(frame.head!.pose.rotation.z, closeTo(0.02, 1e-6));

    final hand = frame.rightHand!;
    expect(hand.hand, TrackedHand.right);
    expect(hand.joints, hasLength(26));
    expect(hand.joints.keys, containsAll(HandJoint.values));
    expect(
      hand.joints[HandJoint.palm]!.pose.translation,
      Vector3(0.2, 1.21, -0.36),
    );
    expect(
      hand.joints[HandJoint.wrist]!.pose.translation,
      Vector3(0.18, 1.18, -0.34),
    );
    expect(hand.palmPose, isNotNull);
  });

  test('XREAL 26-joint OpenXR fixture decodes the production C# wire shape '
      'without a second conversion', () {
    const codec = UnityRelayFrameCodec();
    final frame = codec.decodeString(_read('xreal_26_joint_openxr_frame.json'));

    expect(frame.timeNs, 1900000000000000);
    final head = frame.head!;
    expect(head.pose.translation, Vector3(0.0, 1.62, -0.08));
    expect(head.pose.rotation.x, closeTo(-0.05, 1e-6));
    expect(head.pose.rotation.y, closeTo(0.10, 1e-6));
    expect(head.pose.rotation.z, closeTo(0.02, 1e-6));

    final hand = frame.rightHand!;
    expect(hand.hand, TrackedHand.right);
    expect(hand.joints, hasLength(26));
    expect(hand.joints.keys, containsAll(HandJoint.values));
    expect(
      hand.joints[HandJoint.palm]!.pose.translation,
      Vector3(0.2, 1.21, -0.36),
    );
    expect(
      hand.joints[HandJoint.wrist]!.pose.translation,
      Vector3(0.18, 1.18, -0.34),
    );
  });

  test('XREAL palm anchor positions the controller through the default grip offset', () {
    const codec = UnityRelayFrameCodec();
    final frame = codec.decodeString(_read('xreal_26_joint_unity_frame.json'));
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(frame.withHostTime(frame.timeNs));

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: frame.timeNs,
    );

    expect(pose.source, ControllerPoseSource.handAnchor);
    expect(pose.confidence, TrackingConfidence.high);
    // Converted palm (0.2, 1.21, -0.36) + default grip (0, -0.02, -0.06)
    expect(pose.position!.x, closeTo(0.2, 1e-6));
    expect(pose.position!.y, closeTo(1.19, 1e-6));
    expect(pose.position!.z, closeTo(-0.42, 1e-6));
  });

  test('XREAL grip anchor wins over the palm in Unity space', () {
    const codec = UnityRelayFrameCodec();
    final frame = codec.decodeString(_read('xreal_26_joint_grip_frame.json'));
    final fuser = SixDofFuser();
    fuser.onTrackingFrame(frame.withHostTime(frame.timeNs));

    final pose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: frame.timeNs,
    );

    expect(pose.source, ControllerPoseSource.handAnchor);
    // Converted grip (0.23, 1.17, -0.41) + default grip (0, -0.02, -0.06)
    expect(pose.position!.x, closeTo(0.23, 1e-6));
    expect(pose.position!.y, closeTo(1.15, 1e-6));
    expect(pose.position!.z, closeTo(-0.47, 1e-6));
  });

  test('XREAL frames align onto the BLE host clock and stale hand data is not '
      'fused', () {
    const codec = UnityRelayFrameCodec();
    final frame = codec.decodeString(_read('xreal_26_joint_unity_frame.json'));
    final aligner = SourceClockAligner();
    final fuser = SixDofFuser();
    const arrivalNs = 5000000000;

    final hostNs = aligner.align(
      sourceTimeNs: frame.timeNs,
      hostTimeNs: arrivalNs,
    );
    expect(hostNs, arrivalNs);
    fuser.onTrackingFrame(frame.withHostTime(hostNs));

    final orientation = Quaternion(0.1, 0.2, 0.3, 0.9).normalized();
    final fresh = fuser.update(
      hand: TrackedHand.right,
      orientation: orientation,
      hostTimeNs: arrivalNs,
    );
    expect(fresh.source, ControllerPoseSource.handAnchor);
    expect(fresh.orientation.x, closeTo(orientation.x, 1e-12));
    expect(fresh.orientation.y, closeTo(orientation.y, 1e-12));
    expect(fresh.orientation.z, closeTo(orientation.z, 1e-12));
    expect(fresh.orientation.w, closeTo(orientation.w, 1e-12));

    final stale = fuser.update(
      hand: TrackedHand.right,
      orientation: orientation,
      hostTimeNs:
          arrivalNs + const Duration(milliseconds: 150).inMicroseconds * 1000,
    );
    expect(stale.source, ControllerPoseSource.orientationOnly);
    expect(stale.confidence, TrackingConfidence.none);
    expect(stale.position, isNull);
  });

  test('XREAL relay command fixtures round-trip and reject bad envelopes', () {
    final raw =
        jsonDecode(_read('xreal_relay_commands.json')) as Map<String, Object?>;
    expect(raw['game_object'], UnityRelayCommand.defaultGameObject);
    expect(raw['method'], UnityRelayCommand.defaultMethod);

    final commands = (raw['commands']! as List<Object?>)
        .map(UnityRelayCommand.fromJson)
        .toList();
    expect(commands.map((c) => c.command), ['start', 'stop', 'dispose']);
    for (final command in commands) {
      expect(command.vendor, 'xreal');
      final decoded = UnityRelayCommand.fromJsonString(command.toJsonString());
      expect(decoded.command, command.command);
      expect(decoded.vendor, command.vendor);
      expect(decoded.options, isEmpty);
    }

    expect(
      () => UnityRelayCommand.fromJson({'v': 2, 'cmd': 'start'}),
      throwsFormatException,
    );
    expect(
      () => UnityRelayCommand.fromJson({'v': 1, 'cmd': ''}),
      throwsFormatException,
    );
  });
}
