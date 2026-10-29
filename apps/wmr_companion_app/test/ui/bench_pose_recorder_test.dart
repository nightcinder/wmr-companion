import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion_app/ui/bench/bench_pose.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/pose_recording_store.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// The real recorder writes through the debug screen's pose stream, so these
/// tests drive it with a fake stream rather than a device.
final _recorderProvider = Provider.family<RealBenchPoseRecorder, Directory>(
  (ref, dir) => RealBenchPoseRecorder(
    ref: ref,
    store: PoseRecordingStore(dir),
    runtime: 'viture',
  ),
);

class _FixedTracking extends DebugTrackingSourceNotifier {
  _FixedTracking(this.selection);

  final DebugTrackingSelection selection;

  @override
  DebugTrackingSelection build() => selection;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bench_pose_recorder');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  ProviderContainer containerFor(Stream<DebugPoses> poses) {
    final source = FakeTrackingSource();
    final choice = DebugTrackingSource.viture;
    final container = ProviderContainer(
      overrides: [
        debugTrackingSourceProvider.overrideWith(
          () => _FixedTracking(
            DebugTrackingSelection(
              choice: choice,
              attachment: AsyncValue.data(
                DebugTrackingAttachment(choice: choice, source: source),
              ),
            ),
          ),
        ),
        debugPosesProvider(DebugSource.real).overrideWith((ref) => poses),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  RealBenchPoseRecorder recorderFor(ProviderContainer container) =>
      container.read(_recorderProvider(dir));

  DebugPoses sample(int hostTimeNs) => DebugPoses(
    left: ControllerPose(
      hand: TrackedHand.left,
      hostTimeNs: hostTimeNs,
      orientation: Quaternion.identity(),
      position: Vector3.zero(),
    ),
  );

  test('saves a named file from the live pose stream', () async {
    final poses = StreamController<DebugPoses>();
    addTearDown(poses.close);
    final recorder = recorderFor(containerFor(poses.stream));

    final future = recorder.record(
      hand: 0,
      segment: PoseSegment.still,
      duration: const Duration(milliseconds: 200),
    );
    poses.add(sample(1000));
    final result = await future;

    final file = File(result.path);
    expect(file.existsSync(), isTrue);
    expect(file.uri.pathSegments.last, 'pose_capture_viture_left_still.json');
    expect(result.runtime, 'viture');
    expect(result.samples, 1);
    expect(PoseRecording.decode(file.readAsStringSync()).samples, hasLength(1));
  });

  test('a cancelled segment saves nothing', () async {
    final poses = StreamController<DebugPoses>();
    addTearDown(poses.close);
    final recorder = recorderFor(containerFor(poses.stream));
    final cancel = Completer<void>();

    final future = recorder.record(
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
    final poses = StreamController<DebugPoses>();
    addTearDown(poses.close);
    final recorder = recorderFor(containerFor(poses.stream));

    await expectLater(
      recorder.record(
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
