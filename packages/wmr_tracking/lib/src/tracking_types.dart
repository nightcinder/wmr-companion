import 'pose.dart';

/// Which hand a pose belongs to.
enum TrackedHand {
  left,
  right;

  /// The other hand.
  TrackedHand get opposite =>
      this == TrackedHand.left ? TrackedHand.right : TrackedHand.left;
}

/// A vendor or relay that produces [TrackingFrame]s.
enum TrackingVendor {
  /// ARCore for Jetpack XR on Android XR headsets and wired XR glasses.
  androidXr,

  /// XREAL SDK for Unity (NRSDK 2.x and XREAL SDK 3.x).
  xreal,

  /// VITURE XR Glasses SDK (C) or VITURE XR SDK for Unity.
  viture,

  /// A vendor-neutral relay (native plugin, Unity sidecar or test fixture).
  relay,

  /// In-process fake used by tests and UI development.
  fake,
}

/// Capabilities a tracking source may expose.
///
/// The companion only needs [headPose6Dof] or [handJoints] to lift controller
/// orientation to a position. Everything else is optional.
enum TrackingFeature {
  /// Rotation-only head pose.
  headPose3Dof,

  /// Head pose with position.
  headPose6Dof,

  /// Skeletal hand joints.
  handJoints,

  /// Recognised hand gestures (pinch, select, ...).
  handGestures,

  /// The runtime also reports tracked controller poses. WMR controllers are
  /// not OpenXR devices, so Android XR and the glasses SDKs do not provide
  /// this for them; it is reserved for future native controller support.
  controllerPose,

  /// Raw stereo tracking cameras.
  stereoCamera,

  /// Pass-through RGB camera.
  passthroughCamera,

  /// The tracking cameras have usable near-infrared sensitivity. This is
  /// unconfirmed on every consumer device in `docs/TRACKING.md`.
  nearInfrared,

  /// The vendor exposes a forward-prediction parameter.
  posePrediction,

  /// The tracking origin can be recentred at runtime.
  originReset,
}

/// Confidence reported with a pose. Vendors do not share a scale, so adapters
/// map their tracking state to these four buckets.
enum TrackingConfidence {
  none,
  low,
  medium,
  high;

  bool get usable => this != TrackingConfidence.none;
}

/// What a [TrackingSource] can provide. Adapters must declare this before
/// [TrackingSource.start] so the app can choose an integration path without
/// probing the device.
class TrackingCapabilities {
  const TrackingCapabilities({
    this.features = const {},
    this.handJointCount = 0,
    this.maxHandRateHz = 0,
    this.maxHeadRateHz = 0,
  });

  final Set<TrackingFeature> features;

  /// Number of hand joints per hand, 0 when [TrackingFeature.handJoints] is
  /// absent. OpenXR defines 26; NRSDK 2.4.1 defines 23.
  final int handJointCount;

  /// Nominal rates, 0 when the vendor does not document one.
  final int maxHandRateHz;
  final int maxHeadRateHz;

  bool supports(TrackingFeature feature) => features.contains(feature);

  bool get hasHeadPose =>
      supports(TrackingFeature.headPose3Dof) ||
      supports(TrackingFeature.headPose6Dof);

  bool get hasHead6Dof => supports(TrackingFeature.headPose6Dof);

  bool get hasHandTracking => supports(TrackingFeature.handJoints);

  /// Whether a controller position can be obtained without dead reckoning.
  bool get hasControllerPosition =>
      supports(TrackingFeature.controllerPose) || hasHandTracking;

  static const none = TrackingCapabilities();

  @override
  bool operator ==(Object other) =>
      other is TrackingCapabilities &&
      other.features.length == features.length &&
      other.features.containsAll(features) &&
      other.handJointCount == handJointCount &&
      other.maxHandRateHz == maxHandRateHz &&
      other.maxHeadRateHz == maxHeadRateHz;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(features),
    handJointCount,
    maxHandRateHz,
    maxHeadRateHz,
  );
}

/// A pose plus the tracking state that came with it.
class TrackedPose {
  TrackedPose({required this.pose, this.confidence = TrackingConfidence.high});

  final Pose pose;
  final TrackingConfidence confidence;

  bool get isTracked => confidence.usable;

  Map<String, Object?> toJson() => {
    'pose': pose.toJson(),
    'confidence': confidence.name,
  };

  factory TrackedPose.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('tracked pose must be an object');
    }
    return TrackedPose(
      pose: Pose.fromJson(json['pose']),
      confidence: _confidence(json['confidence']),
    );
  }

  @override
  String toString() => 'TrackedPose($confidence, $pose)';
}

/// Hand joints named after the OpenXR `XrHandJointEXT` set.
///
/// Vendors with fewer joints (NRSDK 2.4.1 has 23, without metacarpals) leave
/// the missing entries out of [HandPose.joints]. [HandPose.palmPose] falls
/// back to the wrist so an anchor is still available.
enum HandJoint {
  wrist,
  palm,
  thumbMetacarpal,
  thumbProximal,
  thumbDistal,
  thumbTip,
  indexMetacarpal,
  indexProximal,
  indexIntermediate,
  indexDistal,
  indexTip,
  middleMetacarpal,
  middleProximal,
  middleIntermediate,
  middleDistal,
  middleTip,
  ringMetacarpal,
  ringProximal,
  ringIntermediate,
  ringDistal,
  ringTip,
  littleMetacarpal,
  littleProximal,
  littleIntermediate,
  littleDistal,
  littleTip,
}

/// One tracked hand.
class HandPose {
  HandPose({
    required this.hand,
    Map<HandJoint, TrackedPose> joints = const {},
    this.palm,
    this.grip,
  }) : joints = Map.unmodifiable(joints);

  final TrackedHand hand;

  /// Joint poses in the tracking space. Missing entries are not tracked.
  final Map<HandJoint, TrackedPose> joints;

  /// Explicit palm pose when the vendor exposes one outside the joint set.
  final TrackedPose? palm;

  /// The controller grip anchor when the vendor exposes one. The framework
  /// uses it instead of the palm for controller position.
  final TrackedPose? grip;

  TrackedPose? joint(HandJoint joint) =>
      joints[joint] ?? (joint == HandJoint.palm ? palm : null);

  /// Palm pose, falling back to the wrist when the SDK has no palm joint.
  TrackedPose? get palmPose =>
      palm ?? joints[HandJoint.palm] ?? joints[HandJoint.wrist];

  /// The best anchor for a held controller.
  TrackedPose? get controllerAnchor => grip ?? palmPose;

  Map<String, Object?> toJson() => {
    'hand': hand.name,
    'joints': {
      for (final entry in joints.entries) entry.key.name: entry.value.toJson(),
    },
    if (palm != null) 'palm': palm!.toJson(),
    if (grip != null) 'grip': grip!.toJson(),
  };

  factory HandPose.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('hand must be an object');
    }
    final hand = _hand(json['hand']);
    final jointsJson = json['joints'];
    final joints = <HandJoint, TrackedPose>{};
    if (jointsJson is Map) {
      for (final entry in jointsJson.entries) {
        final joint = _joint(entry.key);
        if (joint != null) {
          joints[joint] = TrackedPose.fromJson(entry.value);
        }
      }
    }
    return HandPose(
      hand: hand,
      joints: joints,
      palm: json['palm'] == null ? null : TrackedPose.fromJson(json['palm']),
      grip: json['grip'] == null ? null : TrackedPose.fromJson(json['grip']),
    );
  }
}

/// One sample from a tracking source.
class TrackingFrame {
  const TrackingFrame({
    required this.timeNs,
    this.hostTimeNs,
    this.head,
    this.leftHand,
    this.rightHand,
    this.controllers = const {},
  });

  /// Timestamp in the source's own monotonic domain. Adapters copy the
  /// vendor timestamp here without rescaling beyond nanoseconds.
  final int timeNs;

  /// Optional timestamp on the host monotonic clock, in the same domain as
  /// the BLE transport's `receivedAtUs * 1000`. The facade re-stamps frames
  /// with a [SourceClockAligner] when this is absent or needs correction.
  final int? hostTimeNs;

  final TrackedPose? head;
  final HandPose? leftHand;
  final HandPose? rightHand;

  /// Tracked controller poses when the runtime provides them.
  final Map<TrackedHand, TrackedPose> controllers;

  /// The timestamp fusion should use.
  int get fusionTimeNs => hostTimeNs ?? timeNs;

  HandPose? hand(TrackedHand hand) =>
      hand == TrackedHand.left ? leftHand : rightHand;

  TrackedPose? controller(TrackedHand hand) => controllers[hand];

  TrackingFrame withHostTime(int hostTimeNs) => TrackingFrame(
    timeNs: timeNs,
    hostTimeNs: hostTimeNs,
    head: head,
    leftHand: leftHand,
    rightHand: rightHand,
    controllers: controllers,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'time_ns': timeNs,
    if (hostTimeNs != null) 'host_time_ns': hostTimeNs,
    if (head != null) 'head': head!.toJson(),
    if (leftHand != null)
      'hands': {
        'left': leftHand!.toJson(),
        if (rightHand != null) 'right': rightHand!.toJson(),
      }
    else if (rightHand != null)
      'hands': {'right': rightHand!.toJson()},
    if (controllers.isNotEmpty)
      'controllers': {
        for (final entry in controllers.entries)
          entry.key.name: entry.value.toJson(),
      },
  };

  factory TrackingFrame.fromJson(Object? json, {int? hostTimeNs}) {
    if (json is! Map) {
      throw const FormatException('tracking frame must be an object');
    }
    final version = json['v'];
    if (version != null && version != 1) {
      throw FormatException('unsupported tracking frame version: $version');
    }
    final timeNs = _int(json['time_ns'], 'time_ns');
    final handsJson = json['hands'];
    TrackedPose? controllersFor(String name) {
      final controllersJson = json['controllers'];
      if (controllersJson is! Map) return null;
      final value = controllersJson[name];
      return value == null ? null : TrackedPose.fromJson(value);
    }

    return TrackingFrame(
      timeNs: timeNs,
      hostTimeNs: hostTimeNs ?? _optionalInt(json['host_time_ns']),
      head: json['head'] == null ? null : TrackedPose.fromJson(json['head']),
      leftHand: handsJson is Map && handsJson['left'] != null
          ? HandPose.fromJson(handsJson['left'])
          : null,
      rightHand: handsJson is Map && handsJson['right'] != null
          ? HandPose.fromJson(handsJson['right'])
          : null,
      controllers: {
        if (controllersFor('left') case final pose?) TrackedHand.left: pose,
        if (controllersFor('right') case final pose?) TrackedHand.right: pose,
      },
    );
  }
}

TrackingConfidence _confidence(Object? value) {
  if (value == null) return TrackingConfidence.high;
  if (value is! String) {
    throw const FormatException('confidence must be a string');
  }
  return TrackingConfidence.values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => throw FormatException('unknown confidence: $value'),
  );
}

TrackedHand _hand(Object? value) {
  if (value is! String) throw const FormatException('hand must be a string');
  return TrackedHand.values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => throw FormatException('unknown hand: $value'),
  );
}

HandJoint? _joint(Object? value) {
  if (value is! String) return null;
  for (final joint in HandJoint.values) {
    if (joint.name == value) return joint;
  }
  return null;
}

int _int(Object? value, String name) {
  if (value is! int) throw FormatException('$name must be an integer');
  return value;
}

int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is! int)
    throw const FormatException('timestamp must be an integer');
  return value;
}
