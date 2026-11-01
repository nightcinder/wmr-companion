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
/// tests drive it with a fake 6DoF source rather than a device. The host clock
/// is injected so the aligned timestamps are deterministic.
final _recorderProvider =
    Provider.family<RealBenchPoseRecorder, ({Directory dir, HostClock clock})>(
      (ref, key) => RealBenchPoseRecorder(
        ref: ref,
        store: PoseRecordingStore(key.dir),
        runtime: 'viture',
        appCommit: 'abc1234',
        firmwareSha: 'deadbee',
        hostClock: key.clock,
      ),
    );

/// The same recorder with a controller IMU attached, so captures also carry
/// the fused `left`/`right` poses.
final _recorderWithImuProvider =
    Provider.family<RealBenchPoseRecorder, ({Directory dir, HostClock clock})>(
      (ref, key) => RealBenchPoseRecorder(
        ref: ref,
        store: PoseRecordingStore(key.dir),
        runtime: 'viture',
        controllerOrientation: (_) => Quaternion.identity(),
        hostClock: key.clock,
      ),
    );

class _FixedTracking extends DebugTrackingSourceNotifier {
  _FixedTracking(this.selection);

  final DebugTrackingSelection selection;

  @override
  DebugTrackingSelection build() => selection;
}

TrackingFrame _frame(
  int timeNs, {
  bool left = true,
  bool right = true,
  double x = 0,
}) => TrackingFrame(
  timeNs: timeNs,
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
  late List<int> hostArrivals;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bench_pose_recorder');
    hostArrivals = [];
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

  RealBenchPoseRecorder recorder() => container.read(
    _recorderProvider((dir: dir, clock: () => hostArrivals.removeAt(0))),
  );

  /// Feeds one frame and queues the host arrival time the recorder reads when
  /// the fake source delivers it.
  void feed(int sourceNs, {int? hostNs, bool left = true, bool moved = false}) {
    hostArrivals.add(hostNs ?? sourceNs);
    source.addFrame(_frame(sourceNs, left: left, x: moved ? 0.01 : 0));
  }

  test('samples once per anchor frame and writes provenance', () async {
    final subject = recorder();
    final future = subject.record(
      hand: 0,
      segment: PoseSegment.still,
      duration: const Duration(milliseconds: 200),
      run: 2,
    );
    feed(1000000);
    feed(2000000, moved: true);
    feed(3000000, moved: true);
    final result = await future;

    final file = File(result.path);
    expect(file.existsSync(), isTrue);
    expect(
      file.uri.pathSegments.last,
      'pose_capture_viture_left_still_run2.json',
    );
    final recording = PoseRecording.decode(file.readAsStringSync());
    expect(recording.samples, hasLength(3));
    // Every sample is stamped on the host clock, both on the sample and on the
    // embedded frame the fuser would have seen.
    expect(recording.samples.map((sample) => sample.hostTimeNs), [
      1000000,
      2000000,
      3000000,
    ]);
    expect(recording.samples.map((sample) => sample.tracking?.hostTimeNs), [
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

  test('records fused controller poses alongside the tracking frame', () async {
    final subject = container.read(
      _recorderWithImuProvider((
        dir: dir,
        clock: () => hostArrivals.removeAt(0),
      )),
    );
    final future = subject.record(
      hand: 0,
      segment: PoseSegment.still,
      duration: const Duration(milliseconds: 50),
    );
    feed(1000000);
    feed(2000000, moved: true);
    final result = await future;

    final recording = PoseRecording.decode(
      File(result.path).readAsStringSync(),
    );
    expect(recording.samples, hasLength(2));
    final first = recording.samples.first;
    expect(first.left?.hand, TrackedHand.left);
    expect(first.right?.hand, TrackedHand.right);
    expect(first.left?.hostTimeNs, 1000000);
    expect(first.right?.hostTimeNs, 1000000);
    expect(first.left?.orientation.x, 0);
    expect(first.left?.orientation.w, 1);
    expect(first.tracking, isNotNull);
  });

  test('vendor-only timestamps are aligned to the host clock', () async {
    final subject = recorder();
    final future = subject.record(
      hand: 1,
      segment: PoseSegment.still,
      duration: const Duration(milliseconds: 50),
    );
    const vendorNs = 7000000000000;
    feed(vendorNs, hostNs: 5000000);
    feed(vendorNs + 1000000, hostNs: 6000000);
    feed(vendorNs + 2000000, hostNs: 7000000);
    final result = await future;

    final recording = PoseRecording.decode(
      File(result.path).readAsStringSync(),
    );
    expect(recording.samples.map((sample) => sample.hostTimeNs), [
      5000000,
      6000000,
      7000000,
    ]);
    expect(recording.samples.map((sample) => sample.tracking?.hostTimeNs), [
      5000000,
      6000000,
      7000000,
    ]);
    // The vendor timestamp is preserved on the frame, only the host stamp is
    // rewritten.
    expect(recording.samples.map((sample) => sample.tracking?.timeNs), [
      vendorNs,
      vendorNs + 1000000,
      vendorNs + 2000000,
    ]);
    expect(result.anchorRateHz, closeTo(1000, 0.1));
  });

  test('the anchor rate counts only samples with the hand anchor', () async {
    final subject = recorder();
    final future = subject.record(
      hand: 0,
      segment: PoseSegment.still,
      duration: const Duration(milliseconds: 50),
    );
    feed(1000000);
    feed(2000000, left: false);
    feed(3000000, left: false);
    feed(4000000);
    final result = await future;

    final recording = PoseRecording.decode(
      File(result.path).readAsStringSync(),
    );
    // Every frame is written so the occlusion gap stays measurable...
    expect(recording.samples, hasLength(4));
    // ...but the rate is measured over the two anchor-present samples.
    expect(result.anchorRateHz, closeTo(1000 / 3, 0.01));
    expect(recording.provenance['anchor_rate_hz'], closeTo(1000 / 3, 0.01));
  });

  test('run 1 keeps the short file name', () async {
    final subject = recorder();
    final future = subject.record(
      hand: 1,
      segment: PoseSegment.mediumPan,
      duration: const Duration(milliseconds: 50),
    );
    feed(1000, left: false);
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
    feed(1000);
    feed(2000, left: false);
    feed(3000, left: false);
    feed(4000);
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
