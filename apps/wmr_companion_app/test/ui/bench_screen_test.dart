import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/test_bundle.dart';
import 'package:wmr_companion_app/services/test_bundle_export.dart';
import 'package:wmr_companion_app/ui/bench/bench_controller.dart';
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
  Future<BenchStepOutcome> capture() =>
      _outcome(BenchStep.capture, '2400 frames saved');

  @override
  Future<BenchStepOutcome> latency() =>
      _outcome(BenchStep.latency, '8000 rows saved');

  @override
  Future<BenchStepOutcome> poseCapture(
    void Function(BenchCaptureProgress progress) onProgress,
  ) {
    onProgress(
      const BenchCaptureProgress(
        hand: 0,
        segment: PoseSegment.still,
        index: 0,
        total: 10,
      ),
    );
    return _outcome(BenchStep.poseCapture, '10 pose captures saved');
  }
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
    BenchSession session,
  ) async {
    final container = ProviderContainer(
      overrides: [
        benchSessionProvider.overrideWithValue(() async => session),
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

    expect(find.text('Step 2 of 12'), findsOneWidget);
    expect(find.text('Both hands seen'), findsWidgets);

    for (var i = 0; i < 8; i++) {
      await tap(tester, 'bench-start');
    }
    expect(find.text('Step 10 of 12'), findsOneWidget);
    expect(find.text('LED photo'), findsOneWidget);

    await tap(tester, 'bench-confirm');
    expect(find.text('Step 11 of 12'), findsOneWidget);
    await tap(tester, 'bench-confirm');
    expect(find.text('Step 12 of 12'), findsOneWidget);

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
    expect(published.mode, '3dof_only');
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
