import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion_app/ui/bench/bench_controller.dart';
import 'package:wmr_companion_app/ui/bench/bench_hud.dart';
import 'package:wmr_companion_app/ui/bench/bench_pose.dart';
import 'package:wmr_companion_app/ui/bench/bench_run.dart';
import 'package:wmr_companion_app/ui/bench/bench_screen.dart';
import 'package:wmr_companion_app/ui/bench/bench_tracking.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';

class _FixedTracking extends DebugTrackingSourceNotifier {
  _FixedTracking(this.selection);

  final DebugTrackingSelection selection;

  @override
  DebugTrackingSelection build() => selection;
}

class _FixedRealDevice extends RealDeviceController {
  _FixedRealDevice(this.value);

  final RealDeviceState value;

  @override
  RealDeviceState build() => value;
}

const _availableTracking = BenchHandTracking(
  available: true,
  runtime: 'viture',
  label: 'VITURE',
  status: '6DoF: VITURE hand tracking attached (viture runtime).',
);

DebugTrackingSelection _neckbandSelection() => DebugTrackingSelection(
  choice: DebugTrackingSource.auto,
  attachment: AsyncValue.data(
    DebugTrackingAttachment(
      choice: DebugTrackingSource.auto,
      detection: const GlassesDetection(
        vendor: GlassesVendor.viture,
        host: GlassesHost.neckband,
      ),
    ),
  ),
);

Pose _pose(double x) =>
    Pose(translation: Vector3(x, 1.6, -0.5), rotation: Quaternion.identity());

HandPose _hand(TrackedHand hand, double x) => HandPose(
  hand: hand,
  joints: {
    HandJoint.wrist: TrackedPose(
      pose: Pose(
        translation: Vector3(x, 0, 0),
        rotation: Quaternion.identity(),
      ),
    ),
    HandJoint.palm: TrackedPose(
      pose: Pose(
        translation: Vector3(x, 0.04, 0),
        rotation: Quaternion.identity(),
      ),
    ),
    HandJoint.indexTip: TrackedPose(
      pose: Pose(
        translation: Vector3(x, 0.14, 0),
        rotation: Quaternion.identity(),
      ),
    ),
  },
);

void main() {
  test('head motion separates a static 0DoF pose from a moving 6DoF one', () {
    final tracker = BenchHeadMotionTracker(windowSamples: 10);

    tracker.add(_pose(0));
    expect(tracker.motion.moving, isFalse);
    expect(tracker.motion.status, '0DoF head pose: static');
    expect(tracker.motion.deltaLabel, 'Δ —');

    tracker.add(_pose(0.001));
    expect(tracker.motion.moving, isFalse);
    expect(tracker.motion.deltaLabel, 'Δ 0.1 cm');

    tracker.add(_pose(0.05));
    expect(tracker.motion.moving, isTrue);
    expect(tracker.motion.status, '6DoF head pose: moving');
    expect(tracker.motion.deltaLabel, 'Δ 5.0 cm');

    tracker.add(null);
    expect(tracker.motion.samples, 0);
  });

  test('a tracking frame splits into the two hand snapshots', () {
    final hands = benchHandSnapshots(
      TrackingFrame(
        timeNs: 1,
        leftHand: _hand(TrackedHand.left, -0.2),
        rightHand: _hand(TrackedHand.right, 0.2),
      ),
    );

    expect(hands.map((hand) => hand.label), ['LEFT', 'RIGHT']);
    expect(hands.every((hand) => hand.hasJoints), isTrue);
    expect(hands[0].joints, hasLength(3));
    expect(benchHandSnapshots(null).every((hand) => hand.hasJoints), isFalse);
  });

  testWidgets('the HUD paints live hand joints and the head-pose indicator', (
    tester,
  ) async {
    final poses = DebugPoses(
      head: _pose(0),
      tracking: TrackingFrame(
        timeNs: 1,
        leftHand: _hand(TrackedHand.left, -0.2),
        rightHand: _hand(TrackedHand.right, 0.2),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          benchLivePosesProvider.overrideWithValue(AsyncValue.data(poses)),
        ],
        child: const MaterialApp(home: Scaffold(body: BenchTrackingHud())),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('bench-tracking-hud')), findsOneWidget);
    expect(find.byKey(const Key('bench-hand-preview-left')), findsOneWidget);
    expect(find.byKey(const Key('bench-hand-preview-right')), findsOneWidget);
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('RIGHT'), findsOneWidget);
    expect(find.text('3 joints'), findsNWidgets(2));
    expect(find.text('0DoF head pose: static'), findsOneWidget);
    expect(find.byKey(const Key('bench-head-pose-delta')), findsOneWidget);
  });

  testWidgets('a Neckband with no bridge opens in 6DoF only', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        debugTrackingSourceProvider.overrideWith(
          () => _FixedTracking(_neckbandSelection()),
        ),
        realDeviceProvider.overrideWith(
          () => _FixedRealDevice(const RealDeviceState()),
        ),
        benchHandTrackingProvider.overrideWithValue(_availableTracking),
        benchPoseAvailabilityProvider.overrideWithValue(
          const BenchPoseAvailability.available('viture'),
        ),
        benchLivePosesProvider.overrideWithValue(
          AsyncValue.data(const DebugPoses()),
        ),
        benchSessionProvider.overrideWithValue(() async => null),
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

    final state = container.read(benchControllerProvider);
    expect(state.mode, BenchMode.sixDofOnly);
    expect(state.step, BenchStep.deviceSummary);
  });

  test('a connected bridge keeps the 3DoF default', () {
    final container = ProviderContainer(
      overrides: [
        debugTrackingSourceProvider.overrideWith(
          () => _FixedTracking(_neckbandSelection()),
        ),
        realDeviceProvider.overrideWith(
          () => _FixedRealDevice(
            const RealDeviceState(connectedDeviceIds: {'bridge'}),
          ),
        ),
        benchHandTrackingProvider.overrideWithValue(_availableTracking),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(benchDefaultModeProvider), BenchMode.threeDofOnly);
  });
}
