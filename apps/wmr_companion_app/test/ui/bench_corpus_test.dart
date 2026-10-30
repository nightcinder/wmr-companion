import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/bench/bench_controller.dart';
import 'package:wmr_companion_app/ui/bench/bench_pose.dart';
import 'package:wmr_companion_app/ui/bench/bench_run.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/pose_recording_store.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/services/capture_files.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

final _recorderProvider =
    Provider.family<RealBenchPoseRecorder, PoseRecordingStore>(
      (ref, store) => RealBenchPoseRecorder(
        ref: ref,
        store: store,
        runtime: 'viture',
        appCommit: 'abc1234',
        firmwareSha: 'deadbee',
      ),
    );

/// Wraps the real recorder so the test can assert the run duration the wizard
/// passed for every corpus cell.
class _DurationRecorder implements BenchPoseRecorder {
  _DurationRecorder(this.inner);

  final RealBenchPoseRecorder inner;
  final List<Duration> durations = [];

  @override
  String get runtime => inner.runtime;

  @override
  Future<PoseCaptureResult> record({
    required int hand,
    required PoseSegment segment,
    required Duration duration,
    int run = 1,
    Future<void>? cancel,
  }) {
    durations.add(duration);
    return inner.record(
      hand: hand,
      segment: segment,
      duration: duration,
      run: run,
      cancel: cancel,
    );
  }
}

class _FixedTracking extends DebugTrackingSourceNotifier {
  _FixedTracking(this.selection);

  final DebugTrackingSelection selection;

  @override
  DebugTrackingSelection build() => selection;
}

TrackingFrame _frame(int hostNs, {bool left = true, bool right = true}) =>
    TrackingFrame(
      timeNs: hostNs,
      hostTimeNs: hostNs,
      leftHand: left ? _hand(TrackedHand.left, -0.2) : null,
      rightHand: right ? _hand(TrackedHand.right, 0.2) : null,
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

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bench_corpus');
    source = FakeTrackingSource();
    await source.start();
  });

  tearDown(() async {
    await source.dispose();
    dir.deleteSync(recursive: true);
  });

  test('the guided bench records the 4x5x2 corpus with provenance', () async {
    const durations = BenchDurations(
      poseStill: Duration(milliseconds: 12),
      poseDrifting: Duration(milliseconds: 12),
      poseSlowPan: Duration(milliseconds: 12),
      poseMediumPan: Duration(milliseconds: 12),
      poseFastFlick: Duration(milliseconds: 12),
      poseOcclusion: Duration(milliseconds: 12),
    );
    const plan = BenchPosePlan();
    final store = PoseRecordingStore(Directory('${dir.path}/documents'));

    late final _DurationRecorder recorder;
    late final RealBenchSession session;
    final container = ProviderContainer(
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
        benchPoseAvailabilityProvider.overrideWithValue(
          const BenchPoseAvailability.available('viture'),
        ),
        benchDurationsProvider.overrideWithValue(durations),
        poseRecordingStoreProvider.overrideWith((ref) async => store),
        appCommitProvider.overrideWithValue('abc1234'),
        benchSessionProvider.overrideWithValue(() async => session),
        exportTestBundleProvider.overrideWithValue(
          ({BenchBundleRun? benchRun}) => writeTestBundle(
            TestBundleInput(
              now: DateTime(2026, 10, 30, 12),
              appVersion: '0.3.3+8',
              appCommit: 'abc1234',
              phone: 'Test Phone',
              androidVersion: 'Android 14 (API 34)',
              streamMode: 'batched',
              poseCaptures: poseCapturesFromRun(benchRun),
              benchRun: benchRun,
            ),
            Directory('${dir.path}/out'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    recorder = _DurationRecorder(container.read(_recorderProvider(store)));
    session = RealBenchSession(
      tracking: source,
      poseRecorder: recorder,
      clock: MonotonicClock(),
      captureStore: CaptureStore(Directory('${dir.path}/captures')),
      latencyStore: LatencyStore(Directory('${dir.path}/latency')),
      durations: durations,
      appCommit: 'abc1234',
      firmwareSha: 'deadbee',
    );

    final sub = container.listen(benchControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final controller = container.read(benchControllerProvider.notifier);
    controller.selectMode(BenchMode.sixDofOnly);
    controller.skipCurrent(); // the capability summary is not a corpus run

    var tick = 0;
    final feed = Timer.periodic(const Duration(milliseconds: 1), (_) {
      tick++;
      source.addFrame(_frame(tick * 1000000, left: tick % 7 != 0));
    });
    addTearDown(feed.cancel);

    for (var i = 0; i < benchPoseSequence.length; i++) {
      await controller.runCurrent();
    }
    feed.cancel();

    final state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.export);
    expect(recorder.durations, hasLength(42));
    for (var i = 0; i < benchPoseSequence.length; i++) {
      expect(
        recorder.durations[i],
        durations.poseRunDuration(benchPoseSequence[i].segment, plan),
        reason: benchPoseSequence[i].key,
      );
    }
    // Every corpus run is at least the section 8 30 s with the real defaults.
    const realDurations = BenchDurations();
    for (final segment in poseCorpus) {
      expect(
        realDurations.poseRunDuration(segment, plan),
        greaterThanOrEqualTo(const Duration(seconds: 30)),
        reason: segment.id,
      );
    }

    await controller.exportBundle();
    final bundle = container.read(benchControllerProvider);
    expect(bundle.bundleError, isNull);
    final archive = ZipDecoder().decodeBytes(
      File(bundle.bundlePath!).readAsBytesSync(),
    );
    final manifest = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'manifest.md').content
          as List<int>,
    );
    expect(manifest, contains('- Corpus plan: ${plan.signature}'));

    final poseFiles = archive.files
        .where((f) => f.name.startsWith('pose_capture_'))
        .toList();
    expect(poseFiles, hasLength(42));
    final counts = <String, int>{};
    for (final file in poseFiles) {
      final recording = PoseRecording.decode(
        utf8.decode(file.content as List<int>),
      );
      final provenance = recording.provenance;
      expect(provenance['runtime'], 'viture');
      expect(provenance['app_commit'], 'abc1234');
      expect(provenance['firmware_sha'], 'deadbee');
      expect(provenance['anchor_rate_hz'], greaterThan(0));
      final run = provenance['run_index'];
      final hand = provenance['hand'];
      final motion = provenance['motion'];
      expect(run, isA<int>());
      expect(hand, anyOf('LEFT', 'RIGHT'));
      counts['$hand:$motion'] = (counts['$hand:$motion'] ?? 0) + 1;
      if (motion == 'occlusion') {
        final diagnostics = provenance['diagnostics']! as Map;
        expect(diagnostics['occlusion_gaps'], isA<int>());
      }
    }
    for (final hand in ['LEFT', 'RIGHT']) {
      for (final segment in poseCorpus) {
        expect(counts['$hand:${segment.id}'], 4, reason: '$hand ${segment.id}');
      }
      expect(counts['$hand:occlusion'], 1);
    }
  });
}
