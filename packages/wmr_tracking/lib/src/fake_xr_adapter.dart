import 'dart:convert';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'codec.dart';
import 'pose.dart';
import 'tracking_types.dart';
import 'unity_relay.dart';

/// The two JSON adapter contracts a headset adapter can implement.
///
/// [nativeOpenXr] is the plugin/event-channel shape used by
/// `wmr_tracking_android_xr`: `TrackingFrameCodec` JSON already in OpenXR
/// axes. [unityRelay] is the Unity UaaL/sidecar shape: left-handed Unity axes,
/// a `"space": "unity"` tag and Unity `XRHandJointID` joint names, decoded by
/// [UnityRelayFrameCodec].
enum XrAdapterMode {
  nativeOpenXr('native/openxr'),
  unityRelay('unity/relay');

  const XrAdapterMode(this.label);

  /// Human-readable name used in harness output.
  final String label;
}

/// Deterministic synthetic head and 26-joint hand frames for both adapter
/// contracts, with no headset, Unity or Android XR runtime.
///
/// Every generated frame carries a head pose. Hand frames carry both hands and
/// arrive at [handRateHz]; the remaining frames are head-only. [wireMessages]
/// serializes the frames exactly as the matching adapter would send them, so a
/// harness can decode them through [TrackingFrameCodec] (native) or
/// [UnityRelayFrameCodec] (Unity) and check the contract.
class FakeXrAdapter {
  FakeXrAdapter({
    this.mode = XrAdapterMode.nativeOpenXr,
    this.headRateHz = 60,
    this.handRateHz = 30,
    this.duration = const Duration(seconds: 1),
    this.startTimeNs = 1700000000000000,
  }) {
    if (headRateHz <= 0) {
      throw ArgumentError.value(headRateHz, 'headRateHz', 'must be > 0');
    }
    if (handRateHz <= 0 || headRateHz % handRateHz != 0) {
      throw ArgumentError.value(
        handRateHz,
        'handRateHz',
        'must be > 0 and divide headRateHz',
      );
    }
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'must be > 0');
    }
  }

  final XrAdapterMode mode;
  final int headRateHz;
  final int handRateHz;
  final Duration duration;
  final int startTimeNs;

  int get _durationNs => duration.inMicroseconds * 1000;

  int get headPeriodNs => _durationNs ~/ headRateHz;

  int get headFrameCount => _durationNs ~/ headPeriodNs + 1;

  int get handFrameCount => _durationNs ~/ (headPeriodNs * _ratio) + 1;

  int get _ratio => headRateHz ~/ handRateHz;

  /// Generated frames in OpenXR space, oldest first. Every hand frame repeats
  /// the head pose of its head tick.
  List<TrackingFrame> frames() {
    final result = <TrackingFrame>[];
    for (var index = 0; index < headFrameCount; index++) {
      final timeNs = startTimeNs + index * headPeriodNs;
      result.add(
        _frameAt(
          timeNs: timeNs,
          seconds: (timeNs - startTimeNs) / 1e9,
          withHands: index % _ratio == 0,
        ),
      );
    }
    return result;
  }

  /// One JSON message per frame, encoded for [mode].
  List<String> wireMessages() =>
      frames().map(encodeWire).toList(growable: false);

  /// Encodes [frame] the way [mode]'s adapter sends it.
  String encodeWire(TrackingFrame frame) => switch (mode) {
    XrAdapterMode.nativeOpenXr => const TrackingFrameCodec().encodeToString(
      frame,
    ),
    XrAdapterMode.unityRelay => jsonEncode(_unityFrameJson(frame)),
  };

  TrackingFrame _frameAt({
    required int timeNs,
    required double seconds,
    required bool withHands,
  }) {
    final yaw = 0.08 * math.sin(2 * math.pi * seconds);
    return TrackingFrame(
      timeNs: timeNs,
      head: TrackedPose(
        pose: Pose(
          translation: Vector3(0, 1.6, -0.05),
          rotation: Quaternion.axisAngle(Vector3(0, 1, 0), yaw),
        ),
      ),
      leftHand: withHands ? _hand(TrackedHand.left) : null,
      rightHand: withHands ? _hand(TrackedHand.right) : null,
    );
  }

  HandPose _hand(TrackedHand hand) {
    final side = hand == TrackedHand.right ? 1.0 : -1.0;
    final palm = Vector3(0.18 * side, 1.2, -0.35);
    return HandPose(
      hand: hand,
      joints: {
        for (final joint in HandJoint.values)
          joint: TrackedPose(
            pose: Pose(
              translation: joint == HandJoint.palm
                  ? palm
                  : palm + _jointOffset(joint, side),
              rotation: Quaternion.identity(),
            ),
          ),
      },
    );
  }

  /// A small, deterministic skeleton offset from the palm. It is not an
  /// anatomical hand; it only gives every joint a distinct finite pose.
  Vector3 _jointOffset(HandJoint joint, double side) {
    if (joint == HandJoint.wrist) return Vector3(0, -0.03, 0.04);
    final index = joint.index - 2;
    final finger = index ~/ 5;
    final segment = index % 5;
    return Vector3(
      side * (-0.02 + 0.012 * finger),
      0.005 * segment,
      -0.02 - 0.015 * segment,
    );
  }

  /// Unity-space JSON with PascalCase `XRHandJointID` joint names.
  Map<String, Object?> _unityFrameJson(TrackingFrame frame) {
    final unity = openXrToUnityFrame(frame);
    final json = unity.toJson();
    json['space'] = UnityRelayCoordinateSpace.unity.wireName;
    final hands = json['hands'];
    if (hands is Map<String, Object?>) {
      for (final hand in [unity.leftHand, unity.rightHand]) {
        if (hand == null) continue;
        final side = hands[hand.hand.name];
        if (side is! Map<String, Object?>) continue;
        side['joints'] = {
          for (final entry in hand.joints.entries)
            UnityXrHandJoints.unityJointNames[entry.key.index]: entry.value
                .toJson(),
        };
      }
    }
    return json;
  }
}
