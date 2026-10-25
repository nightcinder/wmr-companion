import 'package:vector_math/vector_math_64.dart';

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

  /// Weight of a new position, 1 disables smoothing. Smoothing hides joint
  /// and hand-anchor jitter at the cost of lag.
  final double positionSmoothing;

  /// Maximum number of buffered tracking frames.
  final int maxFrames;

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
      };

  final SixDofFusionConfig _config;
  final Map<TrackedHand, Pose> _gripOffsets;
  final List<TrackingFrame> _frames = [];
  final Map<TrackedHand, Vector3> _lastWorld = {};
  final Map<TrackedHand, Vector3> _headLocal = {};
  final Map<TrackedHand, Vector3> _lastOutput = {};

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
    final frame = _frameFor(hostTimeNs);
    if (frame == null) {
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
    var source = ControllerPoseSource.orientationOnly;
    var confidence = TrackingConfidence.none;

    final runtime = frame.controller(hand);
    if (runtime != null && runtime.isTracked) {
      target = runtime.pose.translation;
      source = ControllerPoseSource.runtimeController;
      confidence = runtime.confidence;
    } else {
      final anchor = frame.hand(hand)?.controllerAnchor;
      if (anchor != null && anchor.isTracked) {
        target = (anchor.pose * _gripOffsets[hand]!).translation;
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

    if (target != null && source != ControllerPoseSource.headRelative) {
      _lastWorld[hand] = Vector3.copy(target);
      if (headPose != null) {
        _headLocal[hand] = headPose.inverse().transformPoint(target);
      }
    }

    if (target != null &&
        source != ControllerPoseSource.headRelative &&
        _config.positionSmoothing < 1) {
      final previous = _lastOutput[hand];
      if (previous != null) {
        target = previous + (target - previous) * _config.positionSmoothing;
      }
    }
    if (target != null) _lastOutput[hand] = Vector3.copy(target);

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
    _gripOffsets[hand] = palm.inverse() * controller;
  }

  /// Clears buffered frames and learned offsets. Per-hand calibration is
  /// kept unless [clearCalibration] is true.
  void reset({bool clearCalibration = false}) {
    _frames.clear();
    _lastWorld.clear();
    _headLocal.clear();
    _lastOutput.clear();
    if (clearCalibration) {
      _gripOffsets[TrackedHand.left] = _config.gripOffset;
      _gripOffsets[TrackedHand.right] = _config.gripOffset;
    }
  }

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
