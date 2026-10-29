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
  _FakeSession({this.failing = const {}, this.throwing = const {}});

  final Set<BenchStep> failing;
  final Set<BenchStep> throwing;

  Future<BenchStepOutcome> _outcome(BenchStep step, String summary) async {
    if (throwing.contains(step)) throw StateError('${step.id} exploded');
    if (failing.contains(step)) {
      return BenchStepOutcome.failed('${step.id} failed');
    }
    return BenchStepOutcome.done(summary);
  }

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
    Duration duration,
  ) => _outcome(
    BenchStep.poseCapture,
    '${hand == 0 ? 'LEFT' : 'RIGHT'} ${segment.id} saved',
  );

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
    return container;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('happy path: one step per screen through the bundle', (
    tester,
  ) async {
    final container = await open(tester, _FakeSession());

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
    expect(find.text('Step 11 of 13'), findsOneWidget);
    expect(find.text('LED photo'), findsOneWidget);
    expect(
      container
          .read(benchControllerProvider)
          .resultFor(BenchStep.poseCapture)
          .status,
      BenchStatus.done,
    );

    await tap(tester, 'bench-confirm');
    expect(find.text('Step 12 of 13'), findsOneWidget);
    await tap(tester, 'bench-confirm');
    expect(find.text('Step 13 of 13'), findsOneWidget);

    await tap(tester, 'bench-export');

    expect(find.textContaining('wmr-ext-20261029.zip'), findsWidgets);
    final state = container.read(benchControllerProvider);
    expect(state.bundlePath, '/tmp/wmr-ext-20261029.zip');
    for (final step in BenchStep.values) {
      expect(state.resultFor(step).status, BenchStatus.done, reason: step.id);
    }
    final published = container.read(benchBundleProvider)!;
    expect(published.steps, hasLength(BenchStep.values.length));
    expect(published.steps.every((s) => s.status == 'done'), isTrue);
    expect(published.steps.map((s) => s.id), BenchStep.values.map((s) => s.id));
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
    expect(find.text('Step 4 of 13'), findsOneWidget);

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
    expect(find.text('Step 2 of 13'), findsOneWidget);

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
    );

    for (var i = 0; i < 10; i++) {
      if (container.read(benchControllerProvider).step == BenchStep.capture) {
        break;
      }
      await tap(tester, 'bench-start');
    }

    final state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.capture);
    final pose = state.resultFor(BenchStep.poseCapture);
    expect(pose.status, BenchStatus.skipped);
    expect(pose.summary, contains('unavailable: no 6DoF hand-tracking source'));
    final published = container.read(benchBundleProvider)!;
    expect(
      published.steps.firstWhere((step) => step.id == 'pose_capture').status,
      'skipped',
    );
  });

  testWidgets('skipping the pose step records every segment and continues', (
    tester,
  ) async {
    final container = await open(tester, _FakeSession());
    for (var i = 0; i < 10; i++) {
      if (container.read(benchControllerProvider).step ==
          BenchStep.poseCapture) {
        break;
      }
      await tap(tester, 'bench-start');
    }
    expect(container.read(benchControllerProvider).step, BenchStep.poseCapture);

    await tap(tester, 'bench-skip');

    final state = container.read(benchControllerProvider);
    expect(state.step, BenchStep.capture);
    expect(state.resultFor(BenchStep.poseCapture).status, BenchStatus.skipped);
    final published = container.read(benchBundleProvider)!;
    final step = published.steps.firstWhere((s) => s.id == 'pose_capture');
    expect(step.status, 'skipped');
    final segments = step.data['segments']! as List;
    expect(segments, hasLength(benchPoseSequence.length));
    expect(
      segments.every((segment) => (segment as Map)['status'] == 'skipped'),
      isTrue,
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
