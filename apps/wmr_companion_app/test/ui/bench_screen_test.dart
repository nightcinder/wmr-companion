import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/bench/bench_controller.dart';
import 'package:wmr_companion_app/ui/bench/bench_pose.dart';
import 'package:wmr_companion_app/ui/bench/bench_run.dart';
import 'package:wmr_companion_app/ui/bench/bench_screen.dart';

class _FakeSession implements BenchSession {
  _FakeSession({
    this.failing = const {},
    this.throwing = const {},
    this.failingSegments = const {},
    this.holdPose = false,
  });

  final Set<BenchStep> failing;
  final Set<BenchStep> throwing;
  final Set<PoseSegment> failingSegments;

  /// When true, a pose segment waits until it is cancelled, as the real
  /// recorder does while it collects samples.
  final bool holdPose;

  Future<BenchStepOutcome> _outcome(BenchStep step, String summary) async {
    if (throwing.contains(step)) throw StateError('${step.id} exploded');
    if (failing.contains(step)) {
      return BenchStepOutcome.failed('${step.id} failed');
    }
    return BenchStepOutcome.done(summary);
  }

  @override
  Future<BenchStepOutcome> deviceSummary() =>
      _outcome(BenchStep.deviceSummary, 'fake: 26 hand joints');

  @override
  Future<BenchStepOutcome> connect() =>
      _outcome(BenchStep.connect, '1 bridge: fake (MTU 185, raw)');

  @override
  Future<BenchStepOutcome> bothHands() =>
      _outcome(BenchStep.bothHands, 'Frames from LEFT and RIGHT');

  @override
  Future<BenchStepOutcome> firmwareConfig() =>
      _outcome(BenchStep.firmwareConfig, 'firmware read, config read');

  @override
  Future<BenchStepOutcome> still(int hand) => _outcome(
    hand == 0 ? BenchStep.stillLeft : BenchStep.stillRight,
    'still 80 frames',
  );

  @override
  Future<BenchStepOutcome> move(int hand) => _outcome(
    hand == 0 ? BenchStep.moveLeft : BenchStep.moveRight,
    'move 80 frames',
  );

  @override
  Future<BenchStepOutcome> poseSegment(
    int hand,
    PoseSegment segment,
    Duration duration, {
    Future<void>? cancel,
  }) async {
    if (holdPose) {
      final stop = Completer<bool>();
      cancel?.then((_) {
        if (!stop.isCompleted) stop.complete(true);
      });
      await stop.future;
      return BenchStepOutcome.failed(
        'skipped by tester',
        data: {
          'runtime': 'viture',
          'hand': hand == 0 ? 'LEFT' : 'RIGHT',
          'segment': segment.id,
        },
      );
    }
    if (failingSegments.contains(segment)) {
      return BenchStepOutcome.failed(
        '${segment.id} failed',
        data: {
          'runtime': 'viture',
          'hand': hand == 0 ? 'LEFT' : 'RIGHT',
          'segment': segment.id,
        },
      );
    }
    return _outcome(
      BenchStep.poseCapture,
      '${hand == 0 ? 'LEFT' : 'RIGHT'} ${segment.id} saved',
    );
  }

  @override
  Future<BenchStepOutcome> capture() =>
      _outcome(BenchStep.capture, '2400 frames saved');

  @override
  Future<BenchStepOutcome> latency() =>
      _outcome(BenchStep.latency, '8000 rows saved');
}

void main() {
  TestBundle bundle() => const TestBundle(
    path: '/tmp/wmr-ext-20261029.zip',
    fileName: 'wmr-ext-20261029.zip',
    present: ['`manifest.md`'],
    missing: [],
  );

  Future<ProviderContainer> open(
    WidgetTester tester,
    BenchSession session, {
    BenchPoseAvailability pose = const BenchPoseAvailability.available(
      'viture',
    ),
    BenchMode mode = BenchMode.threeDofOnly,
  }) async {
    final container = ProviderContainer(
      overrides: [
        benchSessionProvider.overrideWithValue(() async => session),
        benchPoseAvailabilityProvider.overrideWithValue(pose),
        exportTestBundleProvider.overrideWithValue(
          ({BenchBundleRun? benchRun}) async => bundle(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BenchScreen()),
      ),
    );
    // initState runs the connect step after the first frame.
    await tester.pump();
    await tester.pump();
    if (mode != BenchMode.threeDofOnly) {
      container.read(benchControllerProvider.notifier).selectMode(mode);
      await tester.pump();
      await container.read(benchControllerProvider.notifier).runCurrent();
      await tester.pump();
      await tester.pump();
    }
    return container;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pump();
    await tester.pump();
  }

  /// Runs or confirms steps until [target] is on screen.
  Future<void> walkTo(
    WidgetTester tester,
    ProviderContainer container,
    BenchStep target,
  ) async {
    for (var i = 0; i < 40; i++) {
      final state = container.read(benchControllerProvider);
      if (state.step == target) return;
      await tap(tester, state.step.isPrompt ? 'bench-confirm' : 'bench-start');
    }
    fail('did not reach ${target.id}');
  }

  testWidgets('happy path: one step per screen through the bundle', (
    tester,
  ) async {
    final container = await open(
      tester,
      _FakeSession(),
      mode: BenchMode.combined,
    );

    expect(find.text('Step 2 of 13'), findsOneWidget);
    expect(find.text('Both hands seen'), findsWidgets);

    // Walk the measured steps, including all ten pose segments, until the
    // photo prompt.
    for (var i = 0; i < 30; i++) {
      if (container.read(benchControllerProvider).step == BenchStep.photo) {
        break;
      }
      await tap(tester, 'bench-start');
    }
    expect(find.text('Step 10 of 13'), findsOneWidget);
    expect(find.text('LED photo'), findsOneWidget);

    await tap(tester, 'bench-confirm');
    expect(find.text('Step 11 of 13'), findsOneWidget);
    await tap(tester, 'bench-confirm');
    expect(find.textContaining('Step 12 of 13'), findsOneWidget);

    for (var i = 0; i < benchPoseSequence.length; i++) {
      await tap(tester, 'bench-start');
    }
    expect(
      container
          .read(benchControllerProvider)
          .resultFor(BenchStep.poseCapture)
          .status,
      BenchStatus.done,
    );
    expect(find.text('Step 13 of 13'), findsOneWidget);

    await tap(tester, 'bench-export');

    expect(find.textContaining('wmr-ext-20261029.zip'), findsWidgets);
    final state = container.read(benchControllerProvider);
    expect(state.bundlePath, '/tmp/wmr-ext-20261029.zip');
    for (final step in state.steps) {
      expect(state.resultFor(step).status, BenchStatus.done, reason: step.id);
    }
    final published = container.read(benchBundleProvider)!;
    expect(published.steps, hasLength(state.steps.length));
    expect(published.steps.every((s) => s.status == 'done'), isTrue);
    expect(published.steps.map((s) => s.id), state.steps.map((s) => s.id));
    expect(published.mode, 'combined');
  });

  testWidgets('a failed step is shown and can be skipped', (tester) async {
    final container = await open(
      tester,
      _FakeSession(failing: {BenchStep.firmwareConfig}),
    );

    await tap(tester, 'bench-start'); // both hands
    await tap(tester, 'bench-start'); // firmware and config
    expect(find.text('firmware_config failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tap(tester, 'bench-skip');
    expect(find.text('Step 4 of 12'), findsOneWidget);

    final state = container.read(benchControllerProvider);
    expect(
      state.resultFor(BenchStep.firmwareConfig).status,
      BenchStatus.skipped,
    );
    final published = container.read(benchBundleProvider)!;
    final step = published.steps.firstWhere((s) => s.id == 'firmware_config');
    expect(step.status, 'skipped');
  });

  testWidgets('a throwing step becomes a failure without losing the screen', (
    tester,
  ) async {
    final container = await open(
      tester,
      _FakeSession(throwing: {BenchStep.bothHands}),
    );

    await tap(tester, 'bench-start');
    expect(find.textContaining('both_hands exploded'), findsOneWidget);
    expect(find.text('Step 2 of 12'), findsOneWidget);

    final state = container.read(benchControllerProvider);
    expect(state.resultFor(BenchStep.bothHands).status, BenchStatus.failed);
  });

  testWidgets('pose step is skipped when no hand-tracking source is active', (
    tester,
  ) async {
    final container = await open(
      tester,
      _FakeSession(),
      pose: const BenchPoseAvailability.unavailable(
        'unavailable: no 6DoF hand-tracking source',
      ),
      mode: BenchMode.combined,
    );

    for (var i = 0; i < 10; i++) {
      if (container.read(benchControllerProvider).step == BenchStep.photo) {
        break;
      }
      await tap(tester, 'bench-start');
    }
    await tap(tester, 'bench-confirm');
    await tap(tester, 'bench-confirm');

    final state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.export);
    final pose = state.resultFor(BenchStep.poseCapture);
    expect(pose.status, BenchStatus.skipped);
    expect(pose.summary, contains('unavailable: no 6DoF hand-tracking source'));
    final published = container.read(benchBundleProvider)!;
    expect(
      published.steps.firstWhere((step) => step.id == 'pose_capture').status,
      'skipped',
    );
  });

  testWidgets('skipping pose segments records them and continues', (
    tester,
  ) async {
    final container = await open(
      tester,
      _FakeSession(),
      mode: BenchMode.combined,
    );
    await walkTo(tester, container, BenchStep.poseCapture);

    await tap(tester, 'bench-skip');
    var state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.poseCapture);
    expect(state.poseSegment, 1);
    var step = container
        .read(benchBundleProvider)!
        .steps
        .firstWhere((s) => s.id == 'pose_capture');
    var segments = step.data['segments']! as List;
    expect(segments, hasLength(1));
    expect((segments.first as Map)['status'], 'skipped');
    expect((segments.first as Map)['reason'], 'skipped by tester');

    await tap(tester, 'bench-skip-remaining');
    state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.export);
    expect(state.resultFor(BenchStep.poseCapture).status, BenchStatus.skipped);
    step = container
        .read(benchBundleProvider)!
        .steps
        .firstWhere((s) => s.id == 'pose_capture');
    expect(step.status, 'skipped');
    segments = step.data['segments']! as List;
    expect(segments, hasLength(benchPoseSequence.length));
    expect(
      segments.every((segment) => (segment as Map)['status'] == 'skipped'),
      isTrue,
    );
  });

  testWidgets('a segment already recording can be skipped', (tester) async {
    final container = await open(
      tester,
      _FakeSession(holdPose: true),
      mode: BenchMode.combined,
    );
    await walkTo(tester, container, BenchStep.poseCapture);
    await tap(tester, 'bench-start');
    expect(
      container.read(benchControllerProvider).current.status,
      BenchStatus.running,
    );
    expect(find.text('Skip segment'), findsOneWidget);

    await tap(tester, 'bench-skip');
    await tester.pump();

    final state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.poseCapture);
    expect(state.poseSegment, 1);
    final segments =
        container
                .read(benchBundleProvider)!
                .steps
                .firstWhere((s) => s.id == 'pose_capture')
                .data['segments']!
            as List;
    expect(segments, hasLength(1));
    expect((segments.first as Map)['status'], 'skipped');
    expect((segments.first as Map)['reason'], 'skipped by tester');
  });

  testWidgets('a failed segment is recorded skipped and the run continues', (
    tester,
  ) async {
    final container = await open(
      tester,
      _FakeSession(failingSegments: {PoseSegment.still}),
      mode: BenchMode.combined,
    );
    await walkTo(tester, container, BenchStep.poseCapture);
    await tap(tester, 'bench-start'); // the failing still segment

    var state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.poseCapture);
    expect(state.poseSegment, 1);
    var segments =
        container
                .read(benchBundleProvider)!
                .steps
                .firstWhere((s) => s.id == 'pose_capture')
                .data['segments']!
            as List;
    expect((segments.first as Map)['status'], 'skipped');
    expect((segments.first as Map)['reason'], 'still failed');

    for (var i = 1; i < benchPoseSequence.length; i++) {
      await tap(tester, 'bench-start');
    }
    state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.export);
    expect(state.resultFor(BenchStep.poseCapture).status, BenchStatus.done);
    segments =
        container
                .read(benchBundleProvider)!
                .steps
                .firstWhere((s) => s.id == 'pose_capture')
                .data['segments']!
            as List;
    expect(segments, hasLength(benchPoseSequence.length));
    // Both hands' still segments fail; every other segment is recorded.
    expect(
      segments.where((segment) => (segment as Map)['status'] == 'skipped'),
      hasLength(2),
    );
    expect(
      segments.where((segment) => (segment as Map)['status'] == 'done'),
      hasLength(benchPoseSequence.length - 2),
    );
  });

  testWidgets('leaving the screen clears the run before a plain export', (
    tester,
  ) async {
    final container = await open(tester, _FakeSession());
    await tap(tester, 'bench-start');
    expect(container.read(benchBundleProvider), isNotNull);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(container.read(benchBundleProvider), isNull);
  });

  testWidgets('notes an unconnected session instead of crashing', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        benchSessionProvider.overrideWithValue(() async => null),
        exportTestBundleProvider.overrideWithValue(
          ({BenchBundleRun? benchRun}) async => bundle(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BenchScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Not connected to the bridge.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
