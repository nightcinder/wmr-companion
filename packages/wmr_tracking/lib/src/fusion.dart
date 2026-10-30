import 'package:vector_math/vector_math_64.dart';

import 'one_euro.dart';
import 'pose.dart';
import 'tracking_types.dart';

/// Where a controller position came from.
enum ControllerPoseSource {
  /// The XR runtime tracks the controller itself.
  runtimeController,

  /// A hand joint (palm or a vendor grip anchor) plus a calibrated grip
  /// offset positions the controller.
  handAnchor,

  /// No position anchor is available; the last head-local offset keeps the
  /// controller in a plausible place relative to the headset.
  headRelative,

  /// Only the controller's own IMU orientation is available.
  orientationOnly,
}

/// A fused controller pose at a controller sample time.
class ControllerPose {
  ControllerPose({
    required this.hand,
    required this.hostTimeNs,
    required Quaternion orientation,
    Vector3? position,
    this.source = ControllerPoseSource.orientationOnly,
    this.confidence = TrackingConfidence.none,
    this.frameAgeNs,
  }) : orientation = orientation.normalized(),
       position = position == null ? null : Vector3.copy(position);

  final TrackedHand hand;

  /// Host monotonic timestamp, in the same domain as the controller sample's
  /// `receivedAtUs * 1000`.
  final int hostTimeNs;

  /// Fused orientation from the controller IMU.
  final Quaternion orientation;

  /// Controller position in the tracking space, or null when no anchor has
  /// ever been available.
  final Vector3? position;

  final ControllerPoseSource source;
  final TrackingConfidence confidence;

  /// Age of the tracking frame used for the position. Null for
  /// [ControllerPoseSource.orientationOnly].
  final int? frameAgeNs;

  Pose? get pose => position == null
      ? null
      : Pose(translation: position!, rotation: orientation);

  bool get hasPosition => position != null;

  Map<String, Object?> toJson() => {
    'hand': hand.name,
    'host_time_ns': hostTimeNs,
    'orientation': [orientation.x, orientation.y, orientation.z, orientation.w],
    if (position != null) 'position': [position!.x, position!.y, position!.z],
    'source': source.name,
    'confidence': confidence.name,
    if (frameAgeNs != null) 'frame_age_ns': frameAgeNs,
  };

  /// Parses [toJson]. Throws [FormatException] on a malformed value.
  factory ControllerPose.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('controller pose must be an object');
    }
    final hand = _enumValue(TrackedHand.values, json['hand'], 'hand');
    final hostTimeNs = json['host_time_ns'];
    if (hostTimeNs is! int || hostTimeNs < 0) {
      throw const FormatException(
        'host_time_ns must be a non-negative integer',
      );
    }
    final orientation = _quaternion(json['orientation'], 'orientation');
    final rawPosition = json['position'];
    final position = rawPosition == null
        ? null
        : () {
            final values = _vector(rawPosition, 'position');
            return Vector3(values[0], values[1], values[2]);
          }();
    final frameAgeNs = json['frame_age_ns'];
    if (frameAgeNs != null && (frameAgeNs is! int || frameAgeNs < 0)) {
      throw const FormatException(
        'frame_age_ns must be a non-negative integer',
      );
    }
    return ControllerPose(
      hand: hand,
      hostTimeNs: hostTimeNs,
      orientation: orientation,
      position: position,
      source: _enumValue(ControllerPoseSource.values, json['source'], 'source'),
      confidence: _enumValue(
        TrackingConfidence.values,
        json['confidence'],
        'confidence',
      ),
      frameAgeNs: frameAgeNs as int?,
    );
  }

  @override
  String toString() =>
      'ControllerPose(${hand.name}, $source, $confidence, '
      '${position ?? "no position"})';
}

/// Tuning for [SixDofFuser].
class SixDofFusionConfig {
  const SixDofFusionConfig({
    this.maxTrackingAge = const Duration(milliseconds: 100),
    this.lateTolerance = const Duration(milliseconds: 5),
    this.positionSmoothing = 0.5,
    this.maxFrames = 128,
    this.poseFilter = const PoseFilterConfig(),
    this.defaultGripOffset,
    this.leftHeadLocalOffset,
    this.rightHeadLocalOffset,
  });

  /// A tracking frame older than this is not used. 100 ms is about two frames
  /// at 25 Hz (Viture's Carina pose rate) and keeps a stale hand from pinning
  /// the controller after tracking is lost.
  final Duration maxTrackingAge;

  /// A frame may arrive just after the controller sample it matches. Frames
  /// up to this much newer than the sample are still considered.
  final Duration lateTolerance;

  /// Weight of a new runtime-tracked position, 1 disables smoothing. Hand
  /// anchors use [OneEuroFilter] instead, because a fixed EMA adds the same lag
  /// while staying still and while moving. Has no effect on
  /// [ControllerPoseSource.handAnchor].
  final double positionSmoothing;

  /// Maximum number of buffered tracking frames.
  final int maxFrames;

  /// One Euro tuning for hand-anchor positions. The grid tuner supplies a
  /// replacement config once captures exist; the default stays at the
  /// published values until then.
  final PoseFilterConfig poseFilter;

  /// Controller pose relative to the palm, used when no calibration has run.
  /// The default places the controller centre 2 cm below and 6 cm forward of
  /// the palm in OpenXR axes.
  final Pose? defaultGripOffset;

  /// Fallback head-local controller offset used before any real position has
  /// been observed, in metres (OpenXR axes: +X right, +Y up, -Z forward).
  final Vector3? leftHeadLocalOffset;
  final Vector3? rightHeadLocalOffset;

  Pose get gripOffset =>
      defaultGripOffset ??
      Pose(
        translation: Vector3(0, -0.02, -0.06),
        rotation: Quaternion.identity(),
      );

  Vector3 headLocalOffset(TrackedHand hand) {
    final configured = hand == TrackedHand.left
        ? leftHeadLocalOffset
        : rightHeadLocalOffset;
    if (configured != null) return Vector3.copy(configured);
    return hand == TrackedHand.left
        ? Vector3(-0.20, -0.25, -0.30)
        : Vector3(0.20, -0.25, -0.30);
  }
}

/// Lifts controller IMU orientation to a 6DoF pose using head and hand
/// tracking.
///
/// The controller stream runs at roughly 150–180 Hz; tracking frames arrive
/// at 25–90 Hz. [update] picks the newest tracking frame at or before the
/// controller sample and positions the controller from the best available
/// anchor:
///
/// 1. a runtime-tracked controller pose,
/// 2. a hand palm or grip anchor plus [SixDofFusionConfig.gripOffset],
/// 3. a head-relative offset learned from the last real position,
/// 4. orientation only.
///
/// Hand-anchor positions pass through a [OneEuroFilter] on the anchor sample
/// clock, once per new anchor sample; between samples the filtered value is
/// held. The filter sees the anchor joint itself; the grip offset is applied
/// afterwards with the unfiltered IMU orientation, so rotation-induced lever
/// motion is not low-passed. Runtime controller poses keep
/// [SixDofFusionConfig.positionSmoothing]
/// for compatibility, and the head-relative/orientation fallbacks are never
/// smoothed. Crossing between sources resets the filter, so a fallback is not
/// disguised as a tracked hand.
///
/// Orientation always comes from the controller IMU, so it stays at the
/// sample rate. Position sources 1 and 2 are absolute. Source 3 is not true
/// positional tracking: it keeps the controller at a fixed offset from the
/// head and is marked [TrackingConfidence.low]. That is the honest fallback
/// for WMR controllers, which no shipping runtime tracks optically.
class SixDofFuser {
  SixDofFuser({SixDofFusionConfig config = const SixDofFusionConfig()})
    : _config = config,
      _gripOffsets = {
        TrackedHand.left: config.gripOffset,
        TrackedHand.right: config.gripOffset,
      },
      _handFilters = {
        TrackedHand.left: config.poseFilter.createFilter(),
        TrackedHand.right: config.poseFilter.createFilter(),
      };

  final SixDofFusionConfig _config;
  final Map<TrackedHand, Pose> _gripOffsets;
  final List<TrackingFrame> _frames = [];
  final Map<TrackedHand, Vector3> _lastWorld = {};
  final Map<TrackedHand, Vector3> _headLocal = {};
  final Map<TrackedHand, Vector3> _lastOutput = {};
  final Map<TrackedHand, OneEuroFilter> _handFilters;
  final Map<TrackedHand, ControllerPoseSource> _lastSource = {};
  final Map<TrackedHand, int> _anchorFrameTimeNs = {};
  final Map<TrackedHand, Vector3> _heldAnchor = {};

  SixDofFusionConfig get config => _config;

  /// The grip offset in use for [hand].
  Pose gripOffset(TrackedHand hand) => _gripOffsets[hand]!;

  /// Adds a tracking frame. Frames may arrive out of order; the buffer is
  /// sorted and capped at [SixDofFusionConfig.maxFrames].
  void onTrackingFrame(TrackingFrame frame) {
    var index = _frames.length;
    while (index > 0 && _frames[index - 1].fusionTimeNs > frame.fusionTimeNs) {
      index--;
    }
    _frames.insert(index, frame);
    if (_frames.length > _config.maxFrames) {
      _frames.removeRange(0, _frames.length - _config.maxFrames);
    }
  }

  /// Fuses one controller sample.
  ///
  /// [hostTimeNs] is the sample's host monotonic timestamp. The returned pose's
  /// timestamp is the same value; position comes from a tracking frame no
  /// older than [SixDofFusionConfig.maxTrackingAge].
  ControllerPose update({
    required TrackedHand hand,
    required Quaternion orientation,
    required int hostTimeNs,
  }) {
    if (hostTimeNs <= 0) {
      throw ArgumentError.value(
        hostTimeNs,
        'hostTimeNs',
        'must be a positive monotonic timestamp',
      );
    }
    final frame = _frameFor(hostTimeNs);
    if (frame == null) {
      _resetHand(hand);
      return ControllerPose(
        hand: hand,
        hostTimeNs: hostTimeNs,
        orientation: orientation,
        source: ControllerPoseSource.orientationOnly,
        confidence: TrackingConfidence.none,
      );
    }

    final frameAge = hostTimeNs - frame.fusionTimeNs;
    final head = frame.head;
    final headPose = head != null && head.isTracked ? head.pose : null;

    Vector3? target;
    Vector3? worldTarget;
    var source = ControllerPoseSource.orientationOnly;
    var confidence = TrackingConfidence.none;

    final runtime = frame.controller(hand);
    if (runtime != null && runtime.isTracked) {
      target = runtime.pose.translation;
      worldTarget = target;
      source = ControllerPoseSource.runtimeController;
      confidence = runtime.confidence;
    } else {
      final anchor = frame.hand(hand)?.controllerAnchor;
      if (anchor != null && anchor.isTracked) {
        // filter-spec section 3: filter the anchor joint, then apply the grip
        // offset with the unfiltered controller IMU orientation. Filtering the
        // offset-applied position would low-pass rotation-induced lever motion.
        final joint = anchor.pose.translation;
        final offset = Vector3.copy(_gripOffsets[hand]!.translation)
          ..applyQuaternion(orientation);
        target = joint;
        worldTarget = joint + offset;
        source = ControllerPoseSource.handAnchor;
        confidence = anchor.confidence;
      } else if (headPose != null) {
        if (!_headLocal.containsKey(hand)) {
          final lastWorld = _lastWorld[hand];
          if (lastWorld != null) {
            _headLocal[hand] = headPose.inverse().transformPoint(lastWorld);
          }
        }
        final offset = _headLocal[hand] ?? _config.headLocalOffset(hand);
        target = headPose.transformPoint(offset);
        source = ControllerPoseSource.headRelative;
        confidence = TrackingConfidence.low;
      }
    }

    if (target != null && !_isFinite(target)) {
      // A malformed vendor pose must not leak NaN into the transform chain.
      target = null;
      source = ControllerPoseSource.orientationOnly;
      confidence = TrackingConfidence.none;
    }

    if (worldTarget != null && !_isFinite(worldTarget)) {
      // The grip offset is added after the joint guard; a malformed
      // calibration must not leak NaN into the transform chain either.
      worldTarget = null;
      target = null;
      source = ControllerPoseSource.orientationOnly;
      confidence = TrackingConfidence.none;
    }

    final previousSource = _lastSource[hand];
    if (source == ControllerPoseSource.handAnchor &&
        previousSource != ControllerPoseSource.handAnchor) {
      _handFilters[hand]!.reset();
      _clearAnchorState(hand);
    } else if (source == ControllerPoseSource.runtimeController &&
        previousSource != ControllerPoseSource.runtimeController) {
      _lastOutput.remove(hand);
      _clearAnchorState(hand);
    } else if (source == ControllerPoseSource.headRelative) {
      // Never smooth a guess into a tracked anchor, or the other way round.
      _handFilters[hand]!.reset();
      _lastOutput.remove(hand);
      _clearAnchorState(hand);
    }

    if (target != null && source != ControllerPoseSource.headRelative) {
      // Learn the head-local offset from the raw anchor, not the lagging
      // filtered position.
      final world = worldTarget ?? target;
      _lastWorld[hand] = Vector3.copy(world);
      if (headPose != null) {
        _headLocal[hand] = headPose.inverse().transformPoint(world);
      }
    }

    if (target != null && source == ControllerPoseSource.handAnchor) {
      // Filter on the anchor sample's own clock, once per new sample. The
      // controller runs faster than the anchor, so feeding the display tick
      // would shrink dt, inflate the speed estimate and pump the cutoff.
      final anchorTimeNs = frame.fusionTimeNs;
      final lastFrameTime = _anchorFrameTimeNs[hand];
      if (lastFrameTime == null || anchorTimeNs > lastFrameTime) {
        _heldAnchor[hand] = _handFilters[hand]!.filter(target, anchorTimeNs);
        _anchorFrameTimeNs[hand] = anchorTimeNs;
      }
      final joint = _heldAnchor[hand] ?? target;
      target =
          joint +
          (Vector3.copy(_gripOffsets[hand]!.translation)
            ..applyQuaternion(orientation));
      if (!_isFinite(target)) {
        // Re-check after the offset is applied; the guard above only covers
        // the anchor joint.
        target = null;
        source = ControllerPoseSource.orientationOnly;
        confidence = TrackingConfidence.none;
        _clearAnchorState(hand);
      }
    } else if (target != null &&
        source == ControllerPoseSource.runtimeController &&
        _config.positionSmoothing < 1) {
      final previous = _lastOutput[hand];
      if (previous != null) {
        target = previous + (target - previous) * _config.positionSmoothing;
      }
    }
    // A head-relative fallback is only a guess; keeping it would smooth the
    // first real runtime/hand-anchor position toward that guess.
    if (target != null && source != ControllerPoseSource.headRelative) {
      _lastOutput[hand] = Vector3.copy(target);
    }
    _lastSource[hand] = source;

    return ControllerPose(
      hand: hand,
      hostTimeNs: hostTimeNs,
      orientation: orientation,
      position: target,
      source: source,
      confidence: confidence,
      frameAgeNs: frameAge,
    );
  }

  /// Captures the controller pose relative to a palm pose. Call this while
  /// both the hand and the controller are tracked; the vendor-specific
  /// adapter or a user calibration gesture supplies the two poses.
  void calibrateGrip({
    required TrackedHand hand,
    required Pose palm,
    required Pose controller,
  }) {
    // The offset is applied with the live controller IMU orientation, so its
    // translation is stored in the controller/IMU frame. Storing the palm
    // frame translation (palm.inverse() * controller) drops the calibrated
    // palm-to-controller rotation and bends the lever arm.
    final worldOffset = controller.translation - palm.translation;
    _gripOffsets[hand] = Pose(
      translation: rotateVector(controller.rotation.conjugated(), worldOffset),
      rotation: palm.rotation.conjugated() * controller.rotation,
    );
  }

  /// Clears buffered frames, learned offsets and filter state. Per-hand
  /// calibration is kept unless [clearCalibration] is true.
  ///
  /// Call this on a source restart or tracking-origin reset.
  void reset({bool clearCalibration = false}) {
    _frames.clear();
    _lastWorld.clear();
    _headLocal.clear();
    _lastOutput.clear();
    _lastSource.clear();
    _anchorFrameTimeNs.clear();
    _heldAnchor.clear();
    for (final filter in _handFilters.values) {
      filter.reset();
    }
    if (clearCalibration) {
      _gripOffsets[TrackedHand.left] = _config.gripOffset;
      _gripOffsets[TrackedHand.right] = _config.gripOffset;
    }
  }

  void _resetHand(TrackedHand hand) {
    _handFilters[hand]!.reset();
    _lastSource.remove(hand);
    _clearAnchorState(hand);
  }

  void _clearAnchorState(TrackedHand hand) {
    _anchorFrameTimeNs.remove(hand);
    _heldAnchor.remove(hand);
  }

  static bool _isFinite(Vector3 value) =>
      value.x.isFinite && value.y.isFinite && value.z.isFinite;

  TrackingFrame? _frameFor(int hostTimeNs) {
    final tolerance = _config.lateTolerance.inMicroseconds * 1000;
    TrackingFrame? best;
    for (final frame in _frames) {
      if (frame.fusionTimeNs <= hostTimeNs + tolerance) {
        best = frame;
      } else {
        break;
      }
    }
    if (best == null) return null;
    if (hostTimeNs - best.fusionTimeNs >
        _config.maxTrackingAge.inMicroseconds * 1000) {
      return null;
    }
    return best;
  }
}

T _enumValue<T extends Enum>(List<T> values, Object? value, String name) {
  if (value is! String) {
    throw FormatException('$name must be a string');
  }
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('unknown $name: $value');
}

List<double> _vector(Object? value, String name) {
  if (value is! List || value.length != 3) {
    throw FormatException('$name must contain three numbers');
  }
  final out = <double>[];
  for (final element in value) {
    if (element is! num || !element.isFinite) {
      throw FormatException('$name must contain finite numbers');
    }
    out.add(element.toDouble());
  }
  return out;
}

Quaternion _quaternion(Object? value, String name) {
  if (value is! List || value.length != 4) {
    throw FormatException('$name must contain four numbers');
  }
  final out = <double>[];
  for (final element in value) {
    if (element is! num || !element.isFinite) {
      throw FormatException('$name must contain finite numbers');
    }
    out.add(element.toDouble());
  }
  return Quaternion(out[0], out[1], out[2], out[3]);
}
