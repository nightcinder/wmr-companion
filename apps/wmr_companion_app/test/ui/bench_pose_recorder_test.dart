import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion_app/ui/bench/bench_pose.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/pose_recording_store.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// The real recorder listens to the tracking source's own frames, so these
/// tests drive it with a fake 6DoF source rather than a device.
final _recorderProvider = Provider.family<RealBenchPoseRecorder, Directory>(
  (ref, dir) => RealBenchPoseRecorder(
    ref: ref,
    store: PoseRecordingStore(dir),
    runtime: 'viture',
    appCommit: 'abc1234',
    firmwareSha: 'deadbee',
  ),
);

class _FixedTracking extends DebugTrackingSourceNotifier {
  _FixedTracking(this.selection);

  final DebugTrackingSelection selection;

  @override
  DebugTrackingSelection build() => selection;
}

TrackingFrame _frame(
  int hostNs, {
  bool left = true,
  bool right = true,
  double x = 0,
}) => TrackingFrame(
  timeNs: hostNs,
  hostTimeNs: hostNs,
  leftHand: left ? _hand(TrackedHand.left, x) : null,
  rightHand: right ? _hand(TrackedHand.right, x) : null,
);

HandPose _hand(TrackedHand hand, double x) => HandPose(
  hand: hand,
  palm: TrackedPose(
    pose: Pose(translation: Vector3(x, 0, 0), rotation: Quaternion.identity()),
  ),
);

void main() {
  late Directory dir;
  late FakeTrackingSource source;
  late ProviderContainer container;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bench_pose_recorder');
    source = FakeTrackingSource();
    await source.start();
    container = ProviderContainer(
      overrides: [
        debugTrackingSourceProvider.overrideWith(
          () => _FixedTracking(
            DebugTrackingSelection(
              choice: DebugTrackingSource.viture,
              attachment: AsyncValue.data(
                DebugTrackingAttachment(
                  choice: DebugTrackingSource.viture,
                  source: source,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    await source.dispose();
    dir.deleteSync(recursive: true);
  });

  RealBenchPoseRecorder recorder() => container.read(_recorderProvider(dir));

  test('samples once per anchor frame and writes provenance', () async {
    final subject = recorder();
    final future = subject.record(
      hand: 0,
      segment: PoseSegment.still,
      duration: const Duration(milliseconds: 200),
      run: 2,
    );
    source
      ..addFrame(_frame(1000000))
      ..addFrame(_frame(2000000, x: 0.01))
      ..addFrame(_frame(3000000, x: 0.02));
    final result = await future;

    final file = File(result.path);
    expect(file.existsSync(), isTrue);
    expect(
      file.uri.pathSegments.last,
      'pose_capture_viture_left_still_run2.json',
    );
    final recording = PoseRecording.decode(file.readAsStringSync());
    expect(recording.samples, hasLength(3));
    expect(recording.samples.map((sample) => sample.hostTimeNs), [
      1000000,
      2000000,
      3000000,
    ]);
    expect(recording.provenance['runtime'], 'viture');
    expect(recording.provenance['app_commit'], 'abc1234');
    expect(recording.provenance['firmware_sha'], 'deadbee');
    expect(recording.provenance['run_index'], 2);
    expect(recording.provenance['anchor_rate_hz'], closeTo(1000, 0.1));
    expect(result.anchorRateHz, closeTo(1000, 0.1));
  });

  test('run 1 keeps the short file name', () async {
    final subject = recorder();
    final future = subject.record(
      hand: 1,
      segment: PoseSegment.mediumPan,
      duration: const Duration(milliseconds: 50),
    );
    source.addFrame(_frame(1000, left: false));
    final result = await future;

    expect(
      File(result.path).uri.pathSegments.last,
      'pose_capture_viture_right_medium_pan.json',
    );
  });

  test('occlusion captures record the anchor gaps as diagnostics', () async {
    final subject = recorder();
    final future = subject.record(
      hand: 0,
      segment: PoseSegment.occlusion,
      duration: const Duration(milliseconds: 50),
    );
    source
      ..addFrame(_frame(1000))
      ..addFrame(_frame(2000, left: false))
      ..addFrame(_frame(3000, left: false))
      ..addFrame(_frame(4000));
    final result = await future;

    final recording = PoseRecording.decode(
      File(result.path).readAsStringSync(),
    );
    final diagnostics =
        recording.provenance['diagnostics']! as Map<String, Object?>;
    expect(diagnostics['occlusion_gaps'], 1);
    expect(diagnostics['occluded_samples'], 2);
    expect(result.diagnostics['occlusion_gaps'], 1);
  });

  test('a cancelled segment saves nothing', () async {
    final cancel = Completer<void>();
    final subject = recorder();

    final future = subject.record(
      hand: 1,
      segment: PoseSegment.slowPan,
      duration: const Duration(seconds: 10),
      cancel: cancel.future,
    );
    cancel.complete();

    await expectLater(future, throwsA(isA<PoseSegmentCancelled>()));
    expect(dir.existsSync() ? dir.listSync() : const [], isEmpty);
  });

  test('an empty stream fails instead of writing an empty recording', () async {
    await expectLater(
      recorder().record(
        hand: 0,
        segment: PoseSegment.fastFlick,
        duration: const Duration(milliseconds: 30),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('No pose samples arrived'),
        ),
      ),
    );
    expect(dir.existsSync() ? dir.listSync() : const [], isEmpty);
  });
}
