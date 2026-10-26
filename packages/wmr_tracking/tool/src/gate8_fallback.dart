import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// Format tag for the gate 8 JSON evidence file.
const String gate8Format = 'wmr-gate8-fallback-quality';

/// Default evidence path, relative to `packages/wmr_tracking`.
const String gate8DefaultOutputPath = 'build/gate8/fallback_quality.json';

/// Gate 8 expects the head-relative fallback to drift by at least this RMSE.
const double gate8FallbackMinRmseM = 0.05; // 5 cm

/// Gate 8 expects at least one head-relative sample this far from truth.
const double gate8FallbackMinMaxErrorM = 0.10; // 10 cm

/// The rigid control must reproduce the head-local offset this closely.
const double gate8ControlMaxRmseM = 0.000001; // 1 micrometre
const double gate8ControlMaxErrorM = 0.000001; // 1 micrometre

const double _durationS = 10;
const double _headRateHz = 90;
const int _startHostNs = 10000000000; // 10 s, a positive monotonic clock
const double _walkStartS = 3;
const double _walkEndS = 8;
const double _walkSpeedMps = 0.8;
const double _nodHz = 0.5;
const double _nodAmplitudeRad = 20 * math.pi / 180;
const double _yawHz = 0.25;
const double _yawAmplitudeRad = 8 * math.pi / 180;
const double _rollHz = 0.33;
const double _rollAmplitudeRad = 3 * math.pi / 180;
const double _bobHz = 1.8;
const double _bobM = 0.015;

/// Controller world position in the nod/walk trace. It sits still on a table
/// while the head nods and walks away, so a true positional tracker keeps it
/// fixed and the head-relative fallback cannot.
Vector3 _fixedControllerPosition() => Vector3(0.28, 0.95, -0.42);

/// Controller offset in head-local space for the near-zero-error control.
Vector3 _controlHeadLocalOffset() => Vector3(0.18, -0.32, -0.28);

Quaternion _controllerOrientation() =>
    Quaternion.axisAngle(Vector3(0, 0, 1), 0.3);

/// A harness or output error that is not a gate verdict.
class Gate8Exception implements Exception {
  const Gate8Exception(this.message);

  final String message;

  @override
  String toString() => 'Gate8Exception: $message';
}

/// Head pose at [elapsedS]: a nod, a walk and a small walking bob.
Pose headPoseAt(double elapsedS) {
  var walked = 0.0;
  if (elapsedS >= _walkStartS) {
    walked = math.min(elapsedS, _walkEndS) - _walkStartS;
    walked *= _walkSpeedMps;
  }
  final walking = elapsedS >= _walkStartS && elapsedS <= _walkEndS ? 1.0 : 0.0;
  final pitch = _nodAmplitudeRad * math.sin(2 * math.pi * _nodHz * elapsedS);
  final yaw =
      _yawAmplitudeRad * math.sin(2 * math.pi * _yawHz * elapsedS + 0.7);
  final roll = _rollAmplitudeRad * math.sin(2 * math.pi * _rollHz * elapsedS);
  final bob = walking * _bobM * math.sin(2 * math.pi * _bobHz * elapsedS);
  final rotation =
      Quaternion.axisAngle(Vector3(1, 0, 0), pitch) *
      Quaternion.axisAngle(Vector3(0, 1, 0), yaw) *
      Quaternion.axisAngle(Vector3(0, 0, 1), roll);
  return Pose(translation: Vector3(walked, 1.6 + bob, 0), rotation: rotation);
}

/// One evaluated head-relative sample.
class Gate8Sample {
  const Gate8Sample({
    required this.elapsedS,
    required this.expected,
    required this.actual,
    required this.errorM,
    required this.source,
  });

  final double elapsedS;
  final Vector3 expected;
  final Vector3 actual;
  final double errorM;
  final ControllerPoseSource source;
}

/// Positional-error statistics over the head-relative samples.
class Gate8Stats {
  const Gate8Stats({
    required this.samples,
    required this.meanErrorM,
    required this.rmseM,
    required this.p95ErrorM,
    required this.maxErrorM,
    required this.finalErrorM,
    required this.worstAtS,
  });

  final int samples;
  final double meanErrorM;
  final double rmseM;
  final double p95ErrorM;
  final double maxErrorM;
  final double finalErrorM;
  final double worstAtS;

  factory Gate8Stats.fromSamples(List<Gate8Sample> samples) {
    if (samples.isEmpty) {
      throw const Gate8Exception('no head-relative samples were evaluated');
    }
    final errors = [for (final sample in samples) sample.errorM];
    final sorted = [...errors]..sort();
    var sum = 0.0;
    var sumSquares = 0.0;
    var maximum = -1.0;
    var worstAtS = 0.0;
    for (final sample in samples) {
      sum += sample.errorM;
      sumSquares += sample.errorM * sample.errorM;
      if (sample.errorM > maximum) {
        maximum = sample.errorM;
        worstAtS = sample.elapsedS;
      }
    }
    final count = samples.length;
    final p95Index = math.min(count - 1, (0.95 * count).ceil() - 1);
    return Gate8Stats(
      samples: count,
      meanErrorM: sum / count,
      rmseM: math.sqrt(sumSquares / count),
      p95ErrorM: sorted[p95Index],
      maxErrorM: maximum,
      finalErrorM: samples.last.errorM,
      worstAtS: worstAtS,
    );
  }

  Map<String, Object?> toJson() => {
    'samples': samples,
    'mean_error_m': meanErrorM,
    'rmse_m': rmseM,
    'p95_error_m': p95ErrorM,
    'max_error_m': maxErrorM,
    'final_error_m': finalErrorM,
    'worst_at_s': worstAtS,
  };
}

/// The outcome for one synthetic trace.
class Gate8ScenarioResult {
  const Gate8ScenarioResult({
    required this.name,
    required this.expectation,
    required this.verdict,
    required this.passed,
    required this.reason,
    required this.stats,
  });

  final String name;

  /// `fail` for the nod/walk trace, `pass` for the rigid control.
  final String expectation;

  /// `EXPECTED-FAIL`, `PASS`, `UNEXPECTED-PASS` or `FAIL`.
  final String verdict;
  final bool passed;
  final String reason;
  final Gate8Stats stats;

  Map<String, Object?> toJson() => {
    'name': name,
    'expectation': expectation,
    'verdict': verdict,
    'passed': passed,
    'reason': reason,
    ...stats.toJson(),
  };
}

/// Result of running both gate 8 traces.
class Gate8Result {
  const Gate8Result({required this.scenarios, required this.outputPath});

  final List<Gate8ScenarioResult> scenarios;
  final String outputPath;

  Gate8ScenarioResult get fallback =>
      scenarios.firstWhere((scenario) => scenario.name == 'nod_walk');

  Gate8ScenarioResult get control =>
      scenarios.firstWhere((scenario) => scenario.name == 'rigid_control');

  bool get passed => scenarios.every((scenario) => scenario.passed);

  Map<String, Object?> toJson() => {
    'format': gate8Format,
    'gate': 8,
    'verdict': passed ? 'PASS' : 'FAIL',
    'fallback_verdict': fallback.verdict,
    'control_verdict': control.verdict,
    'scenarios': [for (final scenario in scenarios) scenario.toJson()],
    'thresholds': {
      'fallback_min_rmse_m': gate8FallbackMinRmseM,
      'fallback_min_max_error_m': gate8FallbackMinMaxErrorM,
      'control_max_rmse_m': gate8ControlMaxRmseM,
      'control_max_max_error_m': gate8ControlMaxErrorM,
    },
    'output': outputPath,
  };

  /// Runs the nod/walk trace and the rigid control, then writes the JSON
  /// evidence to [outputPath]. Throws [Gate8Exception] if the harness cannot
  /// evaluate a sample, and [FileSystemException] if the evidence cannot be
  /// written.
  static Gate8Result run({String outputPath = gate8DefaultOutputPath}) {
    final scenarios = [
      _replay(name: 'nod_walk', rigidControl: false),
      _replay(name: 'rigid_control', rigidControl: true),
    ];
    final result = Gate8Result(scenarios: scenarios, outputPath: outputPath);
    final file = File(outputPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(result.toJson())}\n',
    );
    return result;
  }

  static Gate8ScenarioResult _replay({
    required String name,
    required bool rigidControl,
  }) {
    final fuser = SixDofFuser(
      config: SixDofFusionConfig(
        rightHeadLocalOffset: _controlHeadLocalOffset(),
      ),
    );
    final seedHead = headPoseAt(0);
    final seedController = rigidControl
        ? seedHead.transformPoint(_controlHeadLocalOffset())
        : _fixedControllerPosition();
    final seedFrame = TrackingFrame(
      timeNs: _startHostNs,
      hostTimeNs: _startHostNs,
      head: TrackedPose(pose: seedHead),
      controllers: {
        TrackedHand.right: TrackedPose(
          pose: Pose(
            translation: seedController,
            rotation: _controllerOrientation(),
          ),
        ),
      },
    );
    fuser.onTrackingFrame(seedFrame);
    final seed = fuser.update(
      hand: TrackedHand.right,
      orientation: _controllerOrientation(),
      hostTimeNs: _startHostNs,
    );
    if (seed.source != ControllerPoseSource.runtimeController) {
      throw Gate8Exception(
        '$name: seed frame produced ${seed.source.name}, '
        'expected runtimeController',
      );
    }

    final samples = <Gate8Sample>[];
    final stepNs = (1e9 / _headRateHz).round();
    final count = (_durationS * _headRateHz).round();
    for (var index = 1; index < count; index++) {
      final hostTimeNs = _startHostNs + index * stepNs;
      final elapsedS = index * stepNs / 1e9;
      final head = headPoseAt(elapsedS);
      fuser.onTrackingFrame(
        TrackingFrame(
          timeNs: hostTimeNs,
          hostTimeNs: hostTimeNs,
          head: TrackedPose(pose: head),
        ),
      );
      final pose = fuser.update(
        hand: TrackedHand.right,
        orientation: _controllerOrientation(),
        hostTimeNs: hostTimeNs,
      );
      if (pose.source != ControllerPoseSource.headRelative) {
        throw Gate8Exception(
          '$name at ${elapsedS.toStringAsFixed(3)} s: '
          'source is ${pose.source.name}, expected headRelative',
        );
      }
      final actual = pose.position!;
      final expected = rigidControl
          ? head.transformPoint(_controlHeadLocalOffset())
          : _fixedControllerPosition();
      samples.add(
        Gate8Sample(
          elapsedS: elapsedS,
          expected: expected,
          actual: actual,
          errorM: (actual - expected).length,
          source: pose.source,
        ),
      );
    }

    final stats = Gate8Stats.fromSamples(samples);
    if (rigidControl) {
      final passed =
          stats.rmseM <= gate8ControlMaxRmseM &&
          stats.maxErrorM <= gate8ControlMaxErrorM;
      return Gate8ScenarioResult(
        name: name,
        expectation: 'pass',
        verdict: passed ? 'PASS' : 'FAIL',
        passed: passed,
        reason: passed
            ? 'fallback reproduces a rigid head-local offset'
            : 'rigid head-local offset was not reproduced',
        stats: stats,
      );
    }
    final drifted =
        stats.rmseM >= gate8FallbackMinRmseM &&
        stats.maxErrorM >= gate8FallbackMinMaxErrorM;
    return Gate8ScenarioResult(
      name: name,
      expectation: 'fail',
      verdict: drifted ? 'EXPECTED-FAIL' : 'UNEXPECTED-PASS',
      passed: drifted,
      reason: drifted
          ? 'head_relative moves with the head, not with the controller'
          : 'fallback stayed unexpectedly close to the fixed controller',
      stats: stats,
    );
  }
}
