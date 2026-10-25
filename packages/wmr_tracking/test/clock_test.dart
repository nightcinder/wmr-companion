import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

void main() {
  test('the first sample establishes the offset', () {
    final aligner = SourceClockAligner();

    final host = aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000);

    expect(host, 5000);
    expect(aligner.offsetNs, 4000);
  });

  test('jitter is low-pass filtered, not copied into the timestamp', () {
    final aligner = SourceClockAligner(smoothing: 0.25);
    aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000);

    final host = aligner.align(sourceTimeNs: 2000, hostTimeNs: 6030);

    expect(host, 2000 + 4008);
    expect(aligner.offsetNs, 4008);
  });

  test('an arrival outlier is rejected but still mapped', () {
    final aligner = SourceClockAligner(
      maxCorrection: const Duration(milliseconds: 50),
    );
    aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000000);

    final host = aligner.align(sourceTimeNs: 2000000, hostTimeNs: 62000000);

    expect(host, 2000000 + 4999000);
    expect(aligner.offsetNs, 4999000);
  });

  test('a delayed frame is mapped with the existing offset', () {
    final aligner = SourceClockAligner();
    aligner.align(sourceTimeNs: 2000000000, hostTimeNs: 5000000000);

    final host = aligner.align(
      sourceTimeNs: 1999900000,
      hostTimeNs: 5000500000,
    );

    expect(host, 1999900000 + 3000000000);
    expect(aligner.offsetNs, 3000000000);
  });

  test('a source clock reset beyond the threshold rebases', () {
    final aligner = SourceClockAligner();
    aligner.align(sourceTimeNs: 2000000000, hostTimeNs: 5000000000);

    final host = aligner.align(sourceTimeNs: 1000, hostTimeNs: 5500000000);

    expect(host, 5500000000);
    expect(aligner.offsetNs, 5499999000);
  });

  test('reset forgets the offset', () {
    final aligner = SourceClockAligner();
    aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000);
    aligner.reset();

    expect(aligner.offsetNs, isNull);
    expect(aligner.align(sourceTimeNs: 1000, hostTimeNs: 9000), 9000);
  });

  test('clock_jitter: irregular timestamps, duplicates and out-of-order frames '
      'keep alignment stable without using future or stale samples', () {
    final aligner = SourceClockAligner();
    final fuser = SixDofFuser(
      config: const SixDofFusionConfig(lateTolerance: Duration.zero),
    );
    const baseSourceNs = 10000000000;
    const baseHostNs = 50000000000;
    const stepNs = 33333333; // 30 Hz

    // Deterministic sequence with arrival jitter, a duplicate source
    // timestamp, an out-of-order frame, and a future frame.
    final events = <(int sourceNs, int arrivalNs, double x)>[
      (baseSourceNs, baseHostNs, 0.10),
      (baseSourceNs + stepNs, baseHostNs + stepNs + 2000000, 0.20),
      // Duplicate timestamp: offset stays finite and stable.
      (baseSourceNs + stepNs, baseHostNs + stepNs + 2500000, 0.20),
      // Frame 3 arrives before Frame 2 (out of order).
      (baseSourceNs + 3 * stepNs, baseHostNs + 3 * stepNs - 1500000, 0.40),
      (baseSourceNs + 2 * stepNs, baseHostNs + 3 * stepNs + 500000, 0.30),
    ];

    for (final (sourceNs, arrivalNs, x) in events) {
      final hostNs = aligner.align(
        sourceTimeNs: sourceNs,
        hostTimeNs: arrivalNs,
      );
      final palm = Pose(
        translation: Vector3(x, 1.22, -0.34),
        rotation: Quaternion.identity(),
      );
      fuser.onTrackingFrame(
        TrackingFrame(
          timeNs: sourceNs,
          hostTimeNs: hostNs,
          rightHand: HandPose(
            hand: TrackedHand.right,
            palm: TrackedPose(pose: palm),
            joints: {HandJoint.palm: TrackedPose(pose: palm)},
          ),
        ),
      );
    }

    // Querying between Frame 2 and Frame 3 must pick Frame 2 (not future
    // Frame 3).
    final midSampleNs = baseHostNs + 2 * stepNs + 5000000;
    final midPose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: midSampleNs,
    );
    expect(midPose.source, ControllerPoseSource.handAnchor);
    expect(midPose.frameAgeNs, greaterThanOrEqualTo(0));
    expect(midPose.frameAgeNs, lessThanOrEqualTo(100000000));
    expect(midPose.position!.x, closeTo(0.30, 1e-6));

    // Querying 200 ms after Frame 3 must reject stale frames (> 100 ms).
    final staleSampleNs = baseHostNs + 3 * stepNs + 200000000;
    final stalePose = fuser.update(
      hand: TrackedHand.right,
      orientation: Quaternion.identity(),
      hostTimeNs: staleSampleNs,
    );
    expect(stalePose.source, ControllerPoseSource.orientationOnly);
    expect(stalePose.position, isNull);
  });
}
