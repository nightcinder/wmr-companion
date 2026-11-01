import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/bench/bench_controller.dart';
import 'package:wmr_companion_app/ui/bench/bench_pose.dart';
import 'package:wmr_companion_app/ui/bench/bench_run.dart';
import 'package:wmr_companion_app/ui/bench/bench_screen.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/pose_recording_store.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

class _FakeSession implements BenchSession {
  @override
  Future<BenchStepOutcome> deviceSummary() async =>
      BenchStepOutcome.done('fake: 26 hand joints');

  @override
  Future<BenchStepOutcome> connect() async => BenchStepOutcome.done('1 bridge');

  @override
  Future<BenchStepOutcome> bothHands() async =>
      BenchStepOutcome.done('Frames from LEFT and RIGHT');

  @override
  Future<BenchStepOutcome> firmwareConfig() async =>
      BenchStepOutcome.done('firmware read, config read');

  @override
  Future<BenchStepOutcome> still(int hand) async =>
      BenchStepOutcome.done('still 80 frames');

  @override
  Future<BenchStepOutcome> move(int hand) async =>
      BenchStepOutcome.done('move 80 frames');

  @override
  Future<BenchStepOutcome> capture() async =>
      BenchStepOutcome.done('2400 frames saved');

  @override
  Future<BenchStepOutcome> latency() async =>
      BenchStepOutcome.done('8000 rows saved');

  @override
  Future<BenchStepOutcome> handTracking({
    required bool gripping,
    required Duration duration,
  }) async => BenchStepOutcome.done(
    gripping ? 'Grip dropout 2.0%' : 'Empty-hand baseline 29.0 Hz',
  );

  @override
  Future<BenchStepOutcome> carinaLeds() async =>
      BenchStepOutcome.done('4 LED captures saved');

  @override
  Future<BenchStepOutcome> carinaCheckerboard() async =>
      BenchStepOutcome.done('10 checkerboard stereo captures saved');

  @override
  Future<BenchStepOutcome> carinaPose() async =>
      BenchStepOutcome.done('Pose 99.0 Hz');

  @override
  Future<BenchStepOutcome> poseSegment(
    int hand,
    PoseSegment segment,
    Duration duration, {
    int run = 1,
    Future<void>? cancel,
  }) async {
    final name = hand == 0 ? 'left' : 'right';
    return BenchStepOutcome.done(
      '$name ${segment.id} run $run: 3 samples',
      data: {
        'runtime': 'fake',
        'hand': name.toUpperCase(),
        'segment': segment.id,
        'run': run,
        'file':
            '/tmp/pose_capture_fake_${name}_${segment.id}'
            '${run > 1 ? '_run$run' : ''}.json',
        'samples': 3,
      },
    );
  }
}

void main() {
  const bundle = TestBundle(
    path: '/tmp/wmr-ext-20261029.zip',
    fileName: 'wmr-ext-20261029.zip',
    present: ['`manifest.md`'],
    missing: [],
  );

  Future<ProviderContainer> open(
    WidgetTester tester, {
    bool withHandJoints = false,
  }) async {
    final documents = Directory.systemTemp.createTempSync('bench_modes_docs');
    addTearDown(() => documents.deleteSync(recursive: true));
    final container = ProviderContainer(
      overrides: [
        benchSessionProvider.overrideWithValue(() async => _FakeSession()),
        poseRecordingStoreProvider.overrideWith(
          (ref) async => PoseRecordingStore(documents),
        ),
        exportTestBundleProvider.overrideWithValue(
          ({BenchBundleRun? benchRun}) async => bundle,
        ),
        if (withHandJoints)
          debugTrackingSourceFactoryProvider.overrideWithValue(
            (choice) async => FakeTrackingSource(),
          ),
      ],
    );
    addTearDown(container.dispose);
    if (withHandJoints) {
      await container
          .read(debugTrackingSourceProvider.notifier)
          .select(DebugTrackingSource.androidXr);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BenchScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    // Unmount the screen while its container is alive; the screen clears the
    // bench bundle in dispose and cannot do that after the container is gone.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    return container;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('6DoF only is disabled without a hand-joint source', (
    tester,
  ) async {
    final container = await open(tester);

    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('bench-mode-6dof_only')),
    );
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('bench-6dof-reason')), findsOneWidget);
    expect(
      find.textContaining('Attach a hand-tracking source'),
      findsOneWidget,
    );
    expect(
      container.read(benchControllerProvider).mode,
      BenchMode.threeDofOnly,
    );
  });

  testWidgets('6DoF only runs without a bridge and records bridge skips', (
    tester,
  ) async {
    final container = await open(tester, withHandJoints: true);

    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('bench-mode-6dof_only')),
    );
    expect(button.onPressed, isNotNull);
    await tap(tester, 'bench-mode-6dof_only');

    final selected = container.read(benchControllerProvider);
    expect(selected.mode, BenchMode.sixDofOnly);
    expect(selected.step, BenchStep.deviceSummary);
    expect(find.text('Device and capability summary'), findsWidgets);
    for (final step in BenchMode.bridgeOnlySteps) {
      expect(selected.resultFor(step).status, BenchStatus.skipped);
      expect(
        selected.resultFor(step).summary,
        contains('No bridge in 6DoF only mode'),
      );
    }

    await tap(tester, 'bench-start');
    expect(container.read(benchControllerProvider).step, BenchStep.handEmpty);
    await tap(tester, 'bench-start');
    expect(container.read(benchControllerProvider).step, BenchStep.handGrip);
    await tap(tester, 'bench-start');
    expect(container.read(benchControllerProvider).step, BenchStep.poseCapture);
    expect(find.byKey(const Key('bench-capture-prompt')), findsOneWidget);
    expect(find.textContaining('Pose 1 of 42'), findsOneWidget);

    await tap(tester, 'bench-start');
    final segment = container.read(benchControllerProvider);
    expect(segment.step, BenchStep.poseCapture);
    expect(segment.poseSegment, 1);

    await tap(tester, 'bench-skip-remaining');
    expect(container.read(benchControllerProvider).step, BenchStep.export);
    final published = container.read(benchBundleProvider)!;
    expect(published.mode, '6dof_only');
    for (final step in BenchMode.bridgeOnlySteps) {
      final recorded = published.steps.firstWhere((s) => s.id == step.id);
      expect(recorded.status, 'skipped');
    }
    final pose = published.steps.firstWhere((s) => s.id == 'pose_capture');
    expect(pose.status, 'done');
    final segments = (pose.data['segments']! as List).cast<Map>();
    expect(segments, hasLength(benchPoseSequence.length));
    expect(segments.first['file'], contains('pose_capture_fake_left'));
  });

  testWidgets('skipping in 6DoF only jumps over the recorded bridge skips', (
    tester,
  ) async {
    final container = await open(tester, withHandJoints: true);
    await tap(tester, 'bench-mode-6dof_only');

    await tap(tester, 'bench-skip');

    expect(container.read(benchControllerProvider).step, BenchStep.handEmpty);
    await tap(tester, 'bench-skip');
    await tap(tester, 'bench-skip');
    expect(container.read(benchControllerProvider).step, BenchStep.poseCapture);
  });

  testWidgets('combined skips the capture visibly with no hand joints', (
    tester,
  ) async {
    final container = await open(tester);
    await tap(tester, 'bench-mode-combined');

    for (var i = 0; i < 9; i++) {
      await tap(tester, 'bench-start');
    }
    await tap(tester, 'bench-confirm');
    await tap(tester, 'bench-confirm');

    final state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.export);
    final capture = state.resultFor(BenchStep.poseCapture);
    expect(capture.status, BenchStatus.skipped);
    expect(capture.summary, contains('no 6DoF hand-tracking source'));

    await tap(tester, 'bench-export');
    expect(
      container
          .read(benchControllerProvider)
          .resultFor(BenchStep.export)
          .status,
      BenchStatus.done,
    );
  });

  test('3DoF only keeps the bridge flow and adds the Carina gates', () {
    expect(BenchMode.threeDofOnly.steps.map((step) => step.id), [
      'connect',
      'both_hands',
      'firmware_config',
      'still_left',
      'still_right',
      'move_left',
      'move_right',
      'capture',
      'latency',
      'photo',
      'serial_log',
      'carina_leds',
      'carina_checkerboard',
      'carina_pose',
      'export',
    ]);
  });
}
