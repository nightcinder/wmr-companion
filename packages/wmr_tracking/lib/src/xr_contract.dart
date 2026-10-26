import 'codec.dart';
import 'fake_xr_adapter.dart';
import 'pose.dart';
import 'tracking_types.dart';
import 'unity_relay.dart';

/// A paired golden frame: the same pose as both adapters put it on the wire.
class XrContractFixture {
  const XrContractFixture({
    required this.name,
    required this.nativeJson,
    required this.unityJson,
  });

  final String name;
  final String nativeJson;
  final String unityJson;
}

/// Head or hand sample rate measured from decoded timestamps.
class XrRateStats {
  const XrRateStats({
    required this.sampleCount,
    required this.firstTimeNs,
    required this.lastTimeNs,
  });

  final int sampleCount;
  final int firstTimeNs;
  final int lastTimeNs;

  /// Samples per second between the first and last timestamp.
  double get hz => sampleCount < 2 || lastTimeNs <= firstTimeNs
      ? 0
      : (sampleCount - 1) * 1e9 / (lastTimeNs - firstTimeNs);

  Map<String, Object?> toJson() => {
    'samples': sampleCount,
    'hz': double.parse(hz.toStringAsFixed(3)),
    'first_ns': firstTimeNs,
    'last_ns': lastTimeNs,
  };
}

/// One adapter mode's replay result.
class XrModeReport {
  const XrModeReport({
    required this.mode,
    required this.frames,
    required this.handFrames,
    required this.head,
    required this.hands,
    required this.jointsPerHand,
    required this.failures,
  });

  final XrAdapterMode mode;
  final int frames;
  final int handFrames;
  final XrRateStats head;
  final XrRateStats hands;

  /// Smallest joint count seen on any hand; 26 is the full OpenXR set.
  final int jointsPerHand;
  final List<String> failures;

  Map<String, Object?> toJson() => {
    'mode': mode.label,
    'frames': frames,
    'hand_frames': handFrames,
    'head': head.toJson(),
    'hands': hands.toJson(),
    'joints_per_hand': jointsPerHand,
    'failures': failures,
  };
}

/// The complete host-only contract result.
class XrContractReport {
  const XrContractReport({
    required this.modes,
    required this.fixturePairs,
    required this.malformedChecked,
    required this.malformedRejected,
    required this.failures,
  });

  final List<XrModeReport> modes;
  final int fixturePairs;
  final int malformedChecked;
  final bool malformedRejected;
  final List<String> failures;

  bool get passes => failures.isEmpty;

  Map<String, Object?> toJson() => {
    'passes': passes,
    'modes': [for (final mode in modes) mode.toJson()],
    'fixture_pairs': fixturePairs,
    'malformed_checked': malformedChecked,
    'malformed_rejected': malformedRejected,
    'failures': failures,
  };
}

/// Replays synthetic head and hand frames through both adapter contracts and
/// reports the achieved rates.
///
/// The native mode uses [TrackingFrameCodec], the Unity mode uses
/// [UnityRelayFrameCodec]. Nothing here touches a plugin, Unity or hardware.
class XrContractHarness {
  const XrContractHarness({
    this.headRateHz = 60,
    this.handRateHz = 30,
    this.duration = const Duration(seconds: 1),
    this.rateToleranceHz = 0.5,
  });

  final int headRateHz;
  final int handRateHz;
  final Duration duration;
  final double rateToleranceHz;

  XrContractReport run({
    required List<XrContractFixture> fixtures,
    required List<String> malformedJson,
  }) {
    final failures = <String>[];
    final modes = [for (final mode in XrAdapterMode.values) _runMode(mode)];
    for (final mode in modes) {
      failures.addAll(mode.failures.map((f) => '${mode.mode.label}: $f'));
    }

    for (final fixture in fixtures) {
      failures.addAll(_checkFixture(fixture));
    }

    var rejected = malformedJson.isNotEmpty;
    for (final message in malformedJson) {
      for (final mode in XrAdapterMode.values) {
        if (!_isRejected(mode, message)) {
          rejected = false;
          failures.add('${mode.label}: malformed input was accepted');
        }
      }
    }

    return XrContractReport(
      modes: modes,
      fixturePairs: fixtures.length,
      malformedChecked: malformedJson.length,
      malformedRejected: rejected,
      failures: failures,
    );
  }

  XrModeReport _runMode(XrAdapterMode mode) {
    final adapter = FakeXrAdapter(
      mode: mode,
      headRateHz: headRateHz,
      handRateHz: handRateHz,
      duration: duration,
    );
    final messages = adapter.wireMessages();
    final failures = <String>[];
    final frames = <TrackingFrame>[];
    for (final message in messages) {
      try {
        frames.add(_decode(mode, message));
      } on FormatException catch (error) {
        failures.add('frame ${frames.length} did not decode: $error');
        break;
      }
    }

    if (frames.length != messages.length) {
      failures.add('decoded ${frames.length} of ${messages.length} frames');
    }

    var previousTimeNs = -1;
    var handFrames = 0;
    var jointsPerHand = HandJoint.values.length;
    for (final frame in frames) {
      if (frame.timeNs <= previousTimeNs) {
        failures.add('timestamps are not strictly increasing');
        break;
      }
      previousTimeNs = frame.timeNs;
      if (frame.head == null) {
        failures.add('frame ${frame.timeNs} has no head pose');
        continue;
      }
      if (frame.head!.confidence != TrackingConfidence.high) {
        failures.add('frame ${frame.timeNs} head confidence is not high');
      }
      final hasHands = frame.leftHand != null || frame.rightHand != null;
      if (!hasHands) continue;
      handFrames++;
      for (final hand in [frame.leftHand, frame.rightHand]) {
        if (hand == null) {
          failures.add('frame ${frame.timeNs} is missing a hand');
          continue;
        }
        if (!hand.joints.containsKey(HandJoint.palm)) {
          failures.add('${hand.hand.name} hand ${frame.timeNs} has no palm');
        }
        if (hand.joints.length < jointsPerHand) {
          jointsPerHand = hand.joints.length;
        }
      }
    }

    final head = _rate(frames.map((frame) => frame.timeNs));
    final hands = _rate(
      frames
          .where((frame) => frame.leftHand != null || frame.rightHand != null)
          .map((frame) => frame.timeNs),
    );
    if ((head.hz - headRateHz).abs() > rateToleranceHz) {
      failures.add(
        'head rate ${head.hz.toStringAsFixed(2)} Hz is not '
        '${headRateHz.toStringAsFixed(2)} Hz',
      );
    }
    if ((hands.hz - handRateHz).abs() > rateToleranceHz) {
      failures.add(
        'hand rate ${hands.hz.toStringAsFixed(2)} Hz is not '
        '${handRateHz.toStringAsFixed(2)} Hz',
      );
    }
    if (jointsPerHand < HandJoint.values.length) {
      failures.add('expected 26 joints per hand, saw $jointsPerHand');
    }

    return XrModeReport(
      mode: mode,
      frames: frames.length,
      handFrames: handFrames,
      head: head,
      hands: hands,
      jointsPerHand: jointsPerHand,
      failures: failures,
    );
  }

  List<String> _checkFixture(XrContractFixture fixture) {
    final failures = <String>[];
    final TrackingFrame native;
    final TrackingFrame unity;
    try {
      native = _decode(XrAdapterMode.nativeOpenXr, fixture.nativeJson);
    } on FormatException catch (error) {
      return ['${fixture.name}: native fixture did not decode: $error'];
    }
    try {
      unity = _decode(XrAdapterMode.unityRelay, fixture.unityJson);
    } on FormatException catch (error) {
      return ['${fixture.name}: Unity fixture did not decode: $error'];
    }
    if (native.head == null || unity.head == null) {
      failures.add('${fixture.name}: head pose is missing');
    } else if (!_samePose(native.head!.pose, unity.head!.pose)) {
      failures.add('${fixture.name}: head pose differs between modes');
    }
    for (final hand in TrackedHand.values) {
      final nativeHand = native.hand(hand);
      final unityHand = unity.hand(hand);
      if (nativeHand == null && unityHand == null) continue;
      if (nativeHand == null || unityHand == null) {
        failures.add('${fixture.name}: ${hand.name} hand is missing');
        continue;
      }
      if (nativeHand.joints.length != HandJoint.values.length ||
          unityHand.joints.length != HandJoint.values.length) {
        failures.add('${fixture.name}: ${hand.name} hand is not 26 joints');
      }
      for (final joint in HandJoint.values) {
        final a = nativeHand.joints[joint];
        final b = unityHand.joints[joint];
        if (a == null || b == null || !_samePose(a.pose, b.pose)) {
          failures.add('${fixture.name}: ${hand.name}.${joint.name} differs');
        }
      }
    }
    return failures;
  }

  bool _isRejected(XrAdapterMode mode, String message) {
    try {
      _decode(mode, message);
      return false;
    } on FormatException {
      return true;
    }
  }

  TrackingFrame _decode(XrAdapterMode mode, String message) => switch (mode) {
    XrAdapterMode.nativeOpenXr => const TrackingFrameCodec().decodeString(
      message,
    ),
    XrAdapterMode.unityRelay => UnityRelayFrameCodec(
      defaultSpace: UnityRelayCoordinateSpace.unity,
    ).decodeString(message),
  };

  XrRateStats _rate(Iterable<int> timestamps) {
    final times = timestamps.toList(growable: false);
    if (times.isEmpty) {
      return const XrRateStats(sampleCount: 0, firstTimeNs: 0, lastTimeNs: 0);
    }
    return XrRateStats(
      sampleCount: times.length,
      firstTimeNs: times.first,
      lastTimeNs: times.last,
    );
  }
}

bool _samePose(Pose a, Pose b) =>
    _close(a.translation.x, b.translation.x) &&
    _close(a.translation.y, b.translation.y) &&
    _close(a.translation.z, b.translation.z) &&
    _close(a.rotation.x, b.rotation.x) &&
    _close(a.rotation.y, b.rotation.y) &&
    _close(a.rotation.z, b.rotation.z) &&
    _close(a.rotation.w, b.rotation.w);

bool _close(double a, double b) => (a - b).abs() <= 1e-6;
