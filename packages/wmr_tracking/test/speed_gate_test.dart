import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// A synthetic XREAL Aura hand trajectory sampled at 90 Hz: one hand anchor
/// moving at a constant [speedMps] along +X for [seconds].
PoseRecording _auraTrajectory(
  double speedMps, {
  double seconds = 10,
  int rateHz = 90,
  TrackedHand hand = TrackedHand.right,
}) {
  final frames = <TrackingFrame>[];
  final count = (seconds * rateHz).round();
  for (var index = 0; index <= count; index++) {
    final time = 1000000000 + index * (1000000000 ~/ rateHz);
    final pose = TrackedPose(
      pose: Pose(
        translation: Vector3(speedMps * index / rateHz, 0, 0),
        rotation: Quaternion.identity(),
      ),
    );
    frames.add(
      TrackingFrame(
        timeNs: time,
        hostTimeNs: time,
        leftHand: hand == TrackedHand.left
            ? HandPose(hand: hand, palm: pose)
            : null,
        rightHand: hand == TrackedHand.right
            ? HandPose(hand: hand, palm: pose)
            : null,
      ),
    );
  }
  return PoseRecording(
    samples: [
      for (final frame in frames)
        PoseRecordingSample(hostTimeNs: frame.hostTimeNs!, tracking: frame),
    ],
    provenance: const {
      'kind': 'synthetic',
      'runtime': 'xreal',
      'device': 'Aura',
      'generator': 'test/speed_gate_test.dart',
    },
  );
}

void main() {
  const evaluator = SpeedGateEvaluator();

  test('a still Aura cell under 2 cm/s passes', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.005),
      hand: TrackedHand.right,
      cell: SpeedGateCell.still,
    );

    expect(result.status, SpeedGateStatus.pass);
    expect(result.passed, isTrue);
    expect(result.medianSpeedMps, closeTo(0.005, 0.0001));
    expect(result.inBandSamples, result.gatedSamples);
    expect(result.reason, contains('0.5 cm/s'));
    expect(result.toJson()['status'], 'pass');
  });

  test('a still Aura cell drifting at 5 cm/s warns', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.05),
      hand: TrackedHand.right,
      cell: SpeedGateCell.still,
    );

    expect(result.status, SpeedGateStatus.warning);
    expect(result.medianSpeedMps, closeTo(0.05, 0.0005));
    expect(result.inBandSamples, 0);
    expect(result.reason, contains('above < 2 cm/s'));
  });

  test('the still band includes exactly 2 cm/s', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.02, hand: TrackedHand.left),
      hand: TrackedHand.left,
      cell: SpeedGateCell.still,
    );

    expect(result.status, SpeedGateStatus.pass, reason: result.reason);
    expect(result.medianSpeedMps, closeTo(0.02, 0.0001));
  });

  test('a drifting Aura cell inside 10-50 cm/s passes', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.25),
      hand: TrackedHand.right,
      cell: SpeedGateCell.drifting,
    );

    expect(result.status, SpeedGateStatus.pass);
    expect(result.medianSpeedMps, closeTo(0.25, 0.001));
    expect(result.toJson()['band_min_mps'], 0.10);
    expect(result.toJson()['band_max_mps'], 0.50);
    expect(result.toJson()['median_speed_mps'], closeTo(0.25, 0.001));
  });

  test('the dynamic band includes both 10 and 50 cm/s edges', () {
    for (final speed in [0.10, 0.50]) {
      final result = evaluator.evaluateRecording(
        _auraTrajectory(speed),
        hand: TrackedHand.right,
        cell: SpeedGateCell.drifting,
      );
      expect(
        result.status,
        SpeedGateStatus.pass,
        reason: '${speed * 100} cm/s',
      );
    }
  });

  test('a drifting Aura cell that barely moves warns below the band', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.04),
      hand: TrackedHand.right,
      cell: SpeedGateCell.drifting,
    );

    expect(result.status, SpeedGateStatus.warning);
    expect(result.medianSpeedMps, closeTo(0.04, 0.0005));
    expect(result.inBandSamples, 0);
    expect(result.reason, contains('below 10-50 cm/s'));
  });

  test('a drifting Aura cell faster than 50 cm/s warns above the band', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.80),
      hand: TrackedHand.right,
      cell: SpeedGateCell.drifting,
    );

    expect(result.status, SpeedGateStatus.warning);
    expect(result.medianSpeedMps, closeTo(0.80, 0.002));
    expect(result.inBandSamples, 0);
    expect(result.reason, contains('above 10-50 cm/s'));
  });

  test('each section 8 moving class passes at its nominal speed', () {
    const nominal = {
      SpeedGateCell.drifting: 0.25,
      SpeedGateCell.slowPan: 0.10,
      SpeedGateCell.mediumPan: 0.50,
      SpeedGateCell.fastFlick: 1.50,
    };
    for (final entry in nominal.entries) {
      final result = evaluator.evaluateRecording(
        _auraTrajectory(entry.value),
        hand: TrackedHand.right,
        cell: entry.key,
      );
      expect(result.status, SpeedGateStatus.pass, reason: entry.key.name);
    }
  });

  test('a fast flick at 150 cm/s passes its own band', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(1.50),
      hand: TrackedHand.right,
      cell: SpeedGateCell.fastFlick,
    );

    expect(result.status, SpeedGateStatus.pass, reason: result.reason);
    expect(result.medianSpeedMps, closeTo(1.50, 0.01));
    expect(result.toJson()['band_min_mps'], 1.125);
    expect(result.toJson()['band_max_mps'], 1.875);
    expect(result.reason, contains('112.5-187.5 cm/s'));
  });

  test('a fast flick performed at 50 cm/s warns below its band', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.50),
      hand: TrackedHand.right,
      cell: SpeedGateCell.fastFlick,
    );

    expect(result.status, SpeedGateStatus.warning);
    expect(result.reason, contains('below 112.5-187.5 cm/s'));
  });

  test('a slow pan performed at 50 cm/s warns above its band', () {
    final result = evaluator.evaluateRecording(
      _auraTrajectory(0.50),
      hand: TrackedHand.right,
      cell: SpeedGateCell.slowPan,
    );

    expect(result.status, SpeedGateStatus.warning);
    expect(result.reason, contains('above 7.5-12.5 cm/s'));
  });

  test("still cells drop the tuner's first 2 s of settling motion", () {
    const rateHz = 90;
    final samples = <SpeedGateSample>[];
    for (var index = 0; index <= 3 * rateHz; index++) {
      final seconds = index / rateHz;
      samples.add(
        SpeedGateSample(
          timeNs: 1000000000 + index * (1000000000 ~/ rateHz),
          position: Vector3(seconds < 2 ? 0.5 * seconds : 1, 0, 0),
        ),
      );
    }

    final result = evaluator.evaluate(samples, cell: SpeedGateCell.still);
    expect(result.status, SpeedGateStatus.pass, reason: result.reason);
    expect(result.medianSpeedMps, closeTo(0, 0.01));

    // A 1 s warm-up would score the settling seconds and warn.
    const oneSecond = SpeedGateEvaluator(warmup: Duration(seconds: 1));
    final shorter = oneSecond.evaluate(samples, cell: SpeedGateCell.still);
    expect(shorter.status, SpeedGateStatus.warning);
  });

  test('a trace with too few samples after warm-up is a warning', () {
    final result = evaluator.evaluate([
      SpeedGateSample(timeNs: 1000000000, position: Vector3.zero()),
      SpeedGateSample(timeNs: 1010000000, position: Vector3(0.001, 0, 0)),
    ], cell: SpeedGateCell.drifting);

    expect(result.status, SpeedGateStatus.warning);
    expect(result.medianSpeedMps, isNull);
    expect(result.gatedSamples, lessThan(3));
    expect(result.reason, contains('warm-up'));
  });

  test(
    'a controller pose wins over the hand anchor and duplicates collapse',
    () {
      final frames = <PoseRecordingSample>[];
      for (var index = 0; index <= 200; index++) {
        final time = 1000000000 + index * 11111111;
        final frame = TrackingFrame(
          timeNs: time,
          hostTimeNs: time,
          rightHand: HandPose(
            hand: TrackedHand.right,
            palm: TrackedPose(
              pose: Pose(
                translation: Vector3(index * 0.01, 0, 0),
                rotation: Quaternion.identity(),
              ),
            ),
          ),
          controllers: {
            TrackedHand.right: TrackedPose(
              pose: Pose(
                translation: Vector3(index * 0.02, 0, 0),
                rotation: Quaternion.identity(),
              ),
            ),
          },
        );
        frames.add(
          PoseRecordingSample(hostTimeNs: frame.hostTimeNs!, tracking: frame),
        );
        // A repeated copy of the same anchor must not invent a zero-speed step.
        if (index.isEven) {
          frames.add(
            PoseRecordingSample(
              hostTimeNs: frame.hostTimeNs! + 1,
              tracking: frame.withHostTime(time),
            ),
          );
        }
      }
      final result = evaluator.evaluateRecording(
        PoseRecording(samples: frames),
        hand: TrackedHand.right,
        cell: SpeedGateCell.drifting,
      );

      // 0.02 m per 11.1 ms is 1.8 m/s, far above the 50 cm/s ceiling.
      expect(result.medianSpeedMps, closeTo(1.8, 0.05));
      expect(result.status, SpeedGateStatus.warning);
    },
  );
}
