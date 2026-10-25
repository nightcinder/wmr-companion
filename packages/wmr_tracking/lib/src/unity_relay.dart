import 'dart:convert';

import 'package:vector_math/vector_math_64.dart';

import 'codec.dart';
import 'pose.dart';
import 'tracking_types.dart';

/// Coordinate convention of a tracking frame arriving over a Unity relay.
enum UnityRelayCoordinateSpace {
  /// Right-handed OpenXR space (+X right, +Y up, -Z forward).
  openXr('openxr'),

  /// Left-handed Unity space (+X right, +Y up, +Z forward).
  unity('unity');

  const UnityRelayCoordinateSpace(this.wireName);

  final String wireName;

  static UnityRelayCoordinateSpace fromWireName(
    Object? value, {
    UnityRelayCoordinateSpace defaultSpace = UnityRelayCoordinateSpace.openXr,
  }) {
    if (value == null) return defaultSpace;
    if (value is! String) {
      throw const FormatException('space must be a string');
    }
    return switch (value) {
      'openxr' => UnityRelayCoordinateSpace.openXr,
      'unity' => UnityRelayCoordinateSpace.unity,
      _ => throw FormatException('unsupported coordinate space: $value'),
    };
  }
}

/// Converts a left-handed Unity [Pose] (`+X` right, `+Y` up, `+Z` forward,
/// `q = [qx, qy, qz, qw]`) to a right-handed OpenXR [Pose] (`+X` right,
/// `+Y` up, `-Z` forward, `p' = [x, y, -z]`, `q' = [-qx, -qy, qz, qw]`).
///
/// Apply only where the Unity coordinate convention is confirmed.
Pose unityToOpenXrPose(Pose unityPose) => Pose(
  translation: Vector3(
    unityPose.translation.x,
    unityPose.translation.y,
    -unityPose.translation.z,
  ),
  rotation: Quaternion(
    -unityPose.rotation.x,
    -unityPose.rotation.y,
    unityPose.rotation.z,
    unityPose.rotation.w,
  ),
);

/// Converts a right-handed OpenXR [Pose] back to a left-handed Unity [Pose].
///
/// Reflections across the XY plane are self-inverse, so this is the exact
/// inverse of [unityToOpenXrPose].
Pose openXrToUnityPose(Pose openXrPose) => unityToOpenXrPose(openXrPose);

/// Converts a Unity-space [TrackedPose] into OpenXR space, preserving
/// [TrackedPose.confidence].
TrackedPose unityToOpenXrTrackedPose(TrackedPose pose) => TrackedPose(
  pose: unityToOpenXrPose(pose.pose),
  confidence: pose.confidence,
);

/// Converts an OpenXR-space [TrackedPose] into Unity space, preserving
/// [TrackedPose.confidence].
TrackedPose openXrToUnityTrackedPose(TrackedPose pose) => TrackedPose(
  pose: openXrToUnityPose(pose.pose),
  confidence: pose.confidence,
);

/// Converts all joints, [HandPose.palm] and [HandPose.grip] of [hand] from
/// Unity space to OpenXR space.
HandPose unityToOpenXrHandPose(HandPose hand) => HandPose(
  hand: hand.hand,
  joints: {
    for (final entry in hand.joints.entries)
      entry.key: unityToOpenXrTrackedPose(entry.value),
  },
  palm: hand.palm == null ? null : unityToOpenXrTrackedPose(hand.palm!),
  grip: hand.grip == null ? null : unityToOpenXrTrackedPose(hand.grip!),
);

/// Converts all joints, [HandPose.palm] and [HandPose.grip] of [hand] from
/// OpenXR space to Unity space.
HandPose openXrToUnityHandPose(HandPose hand) => unityToOpenXrHandPose(hand);

/// Converts a Unity-space [TrackingFrame] to OpenXR space, preserving
/// [TrackingFrame.timeNs] and [TrackingFrame.hostTimeNs].
TrackingFrame unityToOpenXrFrame(TrackingFrame frame) => TrackingFrame(
  timeNs: frame.timeNs,
  hostTimeNs: frame.hostTimeNs,
  head: frame.head == null ? null : unityToOpenXrTrackedPose(frame.head!),
  leftHand: frame.leftHand == null
      ? null
      : unityToOpenXrHandPose(frame.leftHand!),
  rightHand: frame.rightHand == null
      ? null
      : unityToOpenXrHandPose(frame.rightHand!),
  controllers: {
    for (final entry in frame.controllers.entries)
      entry.key: unityToOpenXrTrackedPose(entry.value),
  },
);

/// Converts an OpenXR-space [TrackingFrame] to Unity space.
TrackingFrame openXrToUnityFrame(TrackingFrame frame) =>
    unityToOpenXrFrame(frame);

/// Maps Unity `XRHandJointID` names (`Wrist`..`LittleTip`) and OpenXR camelCase
/// names (`wrist`..`littleTip`) onto the 26-joint [HandJoint] enum.
abstract final class UnityXrHandJoints {
  static const Map<String, HandJoint> _byUnityName = {
    'Wrist': HandJoint.wrist,
    'Palm': HandJoint.palm,
    'ThumbMetacarpal': HandJoint.thumbMetacarpal,
    'ThumbProximal': HandJoint.thumbProximal,
    'ThumbDistal': HandJoint.thumbDistal,
    'ThumbTip': HandJoint.thumbTip,
    'IndexMetacarpal': HandJoint.indexMetacarpal,
    'IndexProximal': HandJoint.indexProximal,
    'IndexIntermediate': HandJoint.indexIntermediate,
    'IndexDistal': HandJoint.indexDistal,
    'IndexTip': HandJoint.indexTip,
    'MiddleMetacarpal': HandJoint.middleMetacarpal,
    'MiddleProximal': HandJoint.middleProximal,
    'MiddleIntermediate': HandJoint.middleIntermediate,
    'MiddleDistal': HandJoint.middleDistal,
    'MiddleTip': HandJoint.middleTip,
    'RingMetacarpal': HandJoint.ringMetacarpal,
    'RingProximal': HandJoint.ringProximal,
    'RingIntermediate': HandJoint.ringIntermediate,
    'RingDistal': HandJoint.ringDistal,
    'RingTip': HandJoint.ringTip,
    'LittleMetacarpal': HandJoint.littleMetacarpal,
    'LittleProximal': HandJoint.littleProximal,
    'LittleIntermediate': HandJoint.littleIntermediate,
    'LittleDistal': HandJoint.littleDistal,
    'LittleTip': HandJoint.littleTip,
  };

  /// All 26 Unity `XRHandJointID` names in OpenXR joint order.
  static List<String> get unityJointNames =>
      _byUnityName.keys.toList(growable: false);

  /// Parses either a Unity `XRHandJointID` PascalCase name or an OpenXR
  /// camelCase [HandJoint] name; returns null for unknown future joints.
  static HandJoint? parse(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final byUnity = _byUnityName[raw];
    if (byUnity != null) return byUnity;
    for (final joint in HandJoint.values) {
      if (joint.name == raw) return joint;
    }
    return null;
  }

  /// Returns the canonical OpenXR camelCase joint key for [raw], or null when
  /// [raw] is not one of the 26 joints.
  static String? normalizeKey(Object? raw) => parse(raw)?.name;
}

/// Versioned command envelope sent from Dart/Kotlin to an embedded Unity
/// tracking relay (`UnityPlayer.UnitySendMessage(gameObject, "OnCommand", json)`).
///
/// This contract is shared across Unity-backed vendor slices (VITURE Pro
/// Neckband, XREAL Air 2 Ultra, and future sidecar relays).
class UnityRelayCommand {
  UnityRelayCommand({
    required this.command,
    this.vendor,
    Map<String, Object?> options = const {},
  }) : options = Map.unmodifiable(options) {
    if (command.trim().isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
  }

  factory UnityRelayCommand.start({
    String? vendor,
    Map<String, Object?> options = const {},
  }) => UnityRelayCommand(command: 'start', vendor: vendor, options: options);

  factory UnityRelayCommand.stop({String? vendor}) =>
      UnityRelayCommand(command: 'stop', vendor: vendor);

  factory UnityRelayCommand.dispose({String? vendor}) =>
      UnityRelayCommand(command: 'dispose', vendor: vendor);

  factory UnityRelayCommand.recenter({String? vendor}) =>
      UnityRelayCommand(command: 'recenter', vendor: vendor);

  factory UnityRelayCommand.configure(
    Map<String, Object?> options, {
    String? vendor,
  }) =>
      UnityRelayCommand(command: 'configure', vendor: vendor, options: options);

  /// Default Unity GameObject name that receives relay commands.
  static const String defaultGameObject = 'WmrTrackingRelay';

  /// Default C# method invoked by `UnitySendMessage`.
  static const String defaultMethod = 'OnCommand';

  /// The command verb (`start`, `stop`, `dispose`, `recenter`, `configure`, ...).
  final String command;

  /// Optional vendor tag (`viture`, `xreal`, ...).
  final String? vendor;

  /// Command-specific parameters (for example `filter_mode` or `aim_sensitivity`).
  final Map<String, Object?> options;

  Map<String, Object?> toJson() => {
    'v': 1,
    'cmd': command,
    if (vendor != null) 'vendor': vendor,
    if (options.isNotEmpty) 'options': options,
  };

  String toJsonString() => jsonEncode(toJson());

  factory UnityRelayCommand.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('relay command must be a JSON object');
    }
    final version = json['v'];
    if (version != 1) {
      throw FormatException('unsupported relay command version: $version');
    }
    final cmd = json['cmd'];
    if (cmd is! String || cmd.trim().isEmpty) {
      throw const FormatException(
        'relay command must have a non-empty string cmd',
      );
    }
    final vendor = json['vendor'];
    if (vendor != null && (vendor is! String || vendor.isEmpty)) {
      throw const FormatException(
        'relay command vendor must be a non-empty string',
      );
    }
    final rawOptions = json['options'];
    final options = <String, Object?>{};
    if (rawOptions != null) {
      if (rawOptions is! Map) {
        throw const FormatException('relay command options must be an object');
      }
      for (final entry in rawOptions.entries) {
        if (entry.key is! String) {
          throw const FormatException(
            'relay command option keys must be strings',
          );
        }
        options[entry.key as String] = entry.value;
      }
    }
    return UnityRelayCommand(
      command: cmd,
      vendor: vendor as String?,
      options: options,
    );
  }

  factory UnityRelayCommand.fromJsonString(String source) =>
      UnityRelayCommand.fromJson(jsonDecode(source));
}

/// Decodes `TrackingFrame` messages from a Unity UaaL or sidecar relay.
///
/// Normalizes Unity `XRHandJointID` joint names to OpenXR camelCase names,
/// rejects non-positive `time_ns` timestamps, and converts Unity left-handed
/// poses to OpenXR right-handed poses when `"space": "unity"` (or
/// [defaultSpace] is [UnityRelayCoordinateSpace.unity]). Frames tagged
/// `"space": "openxr"` are already in OpenXR space and are not converted a
/// second time.
class UnityRelayFrameCodec {
  const UnityRelayFrameCodec({
    this.defaultSpace = UnityRelayCoordinateSpace.openXr,
    this.codec = const TrackingFrameCodec(),
  });

  final UnityRelayCoordinateSpace defaultSpace;
  final TrackingFrameCodec codec;

  TrackingFrame decode(Object? raw, {int? hostTimeNs}) {
    if (raw is! Map) {
      throw const FormatException('relay tracking frame must be a JSON object');
    }
    final normalized = _normalizeFrameMap(raw);
    final space = UnityRelayCoordinateSpace.fromWireName(
      normalized['space'],
      defaultSpace: defaultSpace,
    );
    final frame = codec.decode(normalized, hostTimeNs: hostTimeNs);
    if (frame.timeNs <= 0) {
      throw const FormatException('relay tracking frame time_ns must be > 0');
    }
    return space == UnityRelayCoordinateSpace.unity
        ? unityToOpenXrFrame(frame)
        : frame;
  }

  TrackingFrame decodeString(String source, {int? hostTimeNs}) =>
      decode(jsonDecode(source), hostTimeNs: hostTimeNs);

  Map<String, Object?> _normalizeFrameMap(Map<Object?, Object?> raw) {
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      if (entry.key is String) {
        result[entry.key as String] = entry.value;
      }
    }
    final hands = result['hands'];
    if (hands is Map) {
      final normalizedHands = <String, Object?>{};
      for (final side in const ['left', 'right']) {
        final hand = hands[side];
        if (hand != null) {
          if (hand is! Map) {
            throw const FormatException('hand entry must be an object');
          }
          normalizedHands[side] = _normalizeHandMap(hand, defaultSide: side);
        }
      }
      result['hands'] = normalizedHands;
    }
    return result;
  }

  Map<String, Object?> _normalizeHandMap(
    Map<Object?, Object?> hand, {
    required String defaultSide,
  }) {
    final normalized = <String, Object?>{'hand': defaultSide};
    for (final entry in hand.entries) {
      if (entry.key is String) {
        normalized[entry.key as String] = entry.value;
      }
    }
    final joints = normalized['joints'];
    if (joints is Map) {
      final normalizedJoints = <String, Object?>{};
      for (final entry in joints.entries) {
        final key = entry.key;
        if (key is! String) continue;
        final canonical = UnityXrHandJoints.normalizeKey(key) ?? key;
        normalizedJoints[canonical] = entry.value;
      }
      normalized['joints'] = normalizedJoints;
    }
    return normalized;
  }
}
