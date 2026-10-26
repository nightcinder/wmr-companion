import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/loss_window.dart';
import 'package:wmr_core/domain/orientation.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_companion_ui/wmr_companion_ui.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import 'package:wmr_ble/testing.dart';

import 'raw_mode_notifier.dart';

DebugPoses _poses(ControllerPoseSource source) {
  final position = source == ControllerPoseSource.orientationOnly
      ? null
      : Vector3(0.123, -0.250, -0.300);
  ControllerPose pose(TrackedHand hand) => ControllerPose(
    hand: hand,
    hostTimeNs: 1,
    orientation: quaternionFromEuler(0.5, 0.2, -0.1),
    position: position,
    source: source,
    confidence: source == ControllerPoseSource.orientationOnly
        ? TrackingConfidence.none
        : TrackingConfidence.high,
  );
  return DebugPoses(
    left: pose(TrackedHand.left),
    right: pose(TrackedHand.right),
  );
}

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows orientation, resets yaw and shows stream stats', (
    tester,
  ) async {
    tall(tester);
    final q = quaternionFromEuler(0.5, 0.2, -0.1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamModeProvider.overrideWith(RawModeNotifier.new),
          orientationProvider.overrideWith((ref) => Stream.value(q)),
          streamStatsProvider.overrideWith(
            (ref) => Stream.value(
              const StreamStats(
                hands: [
                  HandStats(frames: 12, lastSequence: 40, gaps: 3),
                  HandStats(),
                ],
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: DebugScreen(source: DebugSource.fake)),
      ),
    );
    await tester.pump();

    expect(find.textContaining('yaw   28.6°'), findsOneWidget);
    expect(
      find.textContaining('LEFT   frames 12  seq 40  gaps 3'),
      findsOneWidget,
    );
    expect(find.textContaining('RIGHT  frames 0  seq -'), findsOneWidget);

    await tester.tap(find.text('Reset orientation'));
    await tester.pump();
    expect(find.textContaining('yaw    0.0°'), findsOneWidget);
    expect(find.textContaining('pitch   11.5°'), findsOneWidget);
  });

  group('stream mode switch', () {
    late FakeTransport transport;
    late ControllerService service;

    Future<void> open(
      WidgetTester tester,
      ControllerService svc, {
      DebugSource source = DebugSource.fake,
    }) async {
      tall(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            orientationProvider.overrideWith(
              (ref) => Stream.value(quaternionFromEuler(0, 0, 0)),
            ),
            streamStatsProvider.overrideWith(
              (ref) => Stream.value(
                const StreamStats(hands: [HandStats(), HandStats()]),
              ),
            ),
            controllerServiceProvider(source).overrideWithValue(svc),
          ],
          child: MaterialApp(home: DebugScreen(source: source)),
        ),
      );
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    setUp(() async {
      transport = FakeTransport(devices: const [fakeBridgeDevice]);
      service = ControllerService(transport, fakeBridgeDeviceId);
      await service.start();
    });
    tearDown(() async {
      await service.dispose();
      await transport.dispose();
    });

    testWidgets('raw to decoded and back switches the subscription', (
      tester,
    ) async {
      await open(tester, service);
      expect(find.text('Raw FF11'), findsOneWidget);
      expect(find.text('Decoded FF12'), findsOneWidget);
      expect(find.text('Recalibrate gyro bias'), findsNothing);
      expect(transport.cccLog, ['on $wmrBridgeStreamCharUuid']);

      await tester.tap(find.text('Decoded FF12'));
      await settle(tester);
      expect(service.mode, StreamMode.decoded);
      expect(transport.cccLog.last, 'on $wmrBridgeDecodedCharUuid');
      expect(find.text('Recalibrate gyro bias'), findsOneWidget);
      expect(find.textContaining('Yaw drifts'), findsOneWidget);
      expect(find.text('LEFT'), findsOneWidget); // hand selector

      await tester.tap(find.text('Raw FF11'));
      await settle(tester);
      expect(service.mode, StreamMode.raw);
      expect(transport.cccLog.last, 'on $wmrBridgeStreamCharUuid');
      expect(find.text('Recalibrate gyro bias'), findsNothing);
      await close(tester);
    });

    testWidgets('batched FF14 feeds the same view and shows batch stats', (
      tester,
    ) async {
      await open(tester, service);
      await tester.tap(find.text('Batched FF14'));
      await settle(tester);
      expect(service.mode, StreamMode.batched);
      expect(transport.cccLog.last, 'on $wmrBridgeBatchedCharUuid');
      expect(find.text('Recalibrate gyro bias'), findsOneWidget);
      expect(find.textContaining('batched on FF14'), findsOneWidget);

      final bridge = FakeWmrBridge(transport);
      for (var i = 0; i < 40; i++) {
        bridge.tick();
      }
      await settle(tester);
      expect(find.textContaining('records 40'), findsNWidgets(2));
      expect(
        find.textContaining('FF14 batches 20  mean 4.00  max 4'),
        findsOneWidget,
      );
      await close(tester);
    });

    testWidgets('decoded mode shows the packet numbers', (tester) async {
      await open(tester, service);
      await tester.tap(find.text('Decoded FF12'));
      await settle(tester);

      final bridge = FakeWmrBridge(
        transport,
        dropRecord: (hand, seq) => hand == 0 && seq % 7 == 3,
      );
      for (var i = 0; i < 120; i++) {
        bridge.tick();
      }
      await settle(tester);

      expect(find.textContaining('records 103'), findsOneWidget);
      expect(find.textContaining('dt p50 10.00 ms'), findsWidgets);
      expect(find.textContaining('missing (ticks)'), findsWidgets);
      expect(find.textContaining('calibrating'), findsWidgets);
      expect(find.textContaining('rate'), findsWidgets);
      expect(find.textContaining('q  w'), findsOneWidget);

      await tester.tap(find.text('Recalibrate gyro bias'));
      await tester.tap(find.text('Reset orientation'));
      await close(tester);
    });

    testWidgets('axis flips are one toggle away and change the service', (
      tester,
    ) async {
      await open(tester, service);
      await tester.tap(find.text('Debug settings'));
      await tester.pumpAndSettle();
      expect(find.textContaining('X=-y Y=+x Z=+z'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(DebugScreen)),
      );
      await tester.tap(find.text('Flip Y'));
      await tester.pump();
      expect(container.read(axisMappingProvider).flip, [false, true, false]);
      expect(find.textContaining('X=-y Y=-x Z=+z'), findsOneWidget);

      await tester.tap(find.text('Gyro Z'));
      await tester.pump();
      expect(container.read(axisMappingProvider).gyroFlip, [
        false,
        false,
        true,
      ]);
      await tester.tap(find.text('Reset to default table'));
      await tester.pump();
      expect(container.read(axisMappingProvider).flip, [false, false, false]);
      await close(tester);
    });

    testWidgets('fusion sliders tune and clamp to their bounds', (
      tester,
    ) async {
      await open(tester, service);
      await tester.tap(find.text('Debug settings'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DebugScreen)),
      );

      expect(find.textContaining('Madgwick Beta 0.05'), findsOneWidget);
      final beta = find.byKey(const ValueKey('madgwick-beta-slider'));
      expect(beta, findsOneWidget);
      await tester.ensureVisible(beta);
      await tester.pumpAndSettle();

      var rect = tester.getRect(beta);
      await tester.tapAt(Offset(rect.left + 1, rect.center.dy));
      await tester.pump();
      expect(container.read(filterTuningProvider).beta, madgwickBetaMin);

      await tester.tapAt(Offset(rect.right - 1, rect.center.dy));
      await tester.pump();
      expect(container.read(filterTuningProvider).beta, madgwickBetaMax);
      expect(find.textContaining('Madgwick Beta 0.20'), findsOneWidget);

      await tester.tap(find.text('Mahony'));
      await tester.pumpAndSettle();
      expect(beta, findsNothing);
      expect(find.textContaining('Mahony Kp 1.00'), findsOneWidget);
      expect(find.textContaining('Mahony Ki 0.00'), findsOneWidget);

      final kp = find.byKey(const ValueKey('mahony-kp-slider'));
      await tester.ensureVisible(kp);
      await tester.pumpAndSettle();
      rect = tester.getRect(kp);
      await tester.tapAt(Offset(rect.right - 1, rect.center.dy));
      await tester.pump();
      expect(container.read(filterTuningProvider).mahonyKp, mahonyKpMax);

      final ki = find.byKey(const ValueKey('mahony-ki-slider'));
      await tester.ensureVisible(ki);
      await tester.pumpAndSettle();
      rect = tester.getRect(ki);
      await tester.tapAt(Offset(rect.left + 1, rect.center.dy));
      await tester.pump();
      expect(container.read(filterTuningProvider).mahonyKi, mahonyKiMin);

      await tester.ensureVisible(find.text('Madgwick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Madgwick'));
      await tester.pumpAndSettle();
      expect(
        container.read(filterTuningProvider).beta,
        madgwickBetaMax,
        reason: 'the Madgwick value is kept while Mahony is selected',
      );
      await close(tester);
    });
  });

  group('faults are shown', () {
    late FakeBleAdapter adapter;
    late UniversalBleTransport real;
    late ControllerService service;

    setUp(() async {
      adapter = FakeBleAdapter();
      real = UniversalBleTransport(adapter: adapter);
      service = ControllerService(real, fakeBridgeDeviceId);
      await service.start();
    });
    tearDown(() async {
      await service.dispose();
      await real.dispose();
    });

    testWidgets('a refused switch is a banner, not silence', (tester) async {
      tall(tester);
      adapter.disableErrors[wmrBridgeStreamCharUuid] =
          const BleAdapterException('refused');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            orientationProvider.overrideWith(
              (ref) => Stream.value(quaternionFromEuler(0, 0, 0)),
            ),
            streamStatsProvider.overrideWith(
              (ref) => Stream.value(
                const StreamStats(hands: [HandStats(), HandStats()]),
              ),
            ),
            controllerServiceProvider(DebugSource.fake)
                .overrideWithValue(service),
          ],
          child: const MaterialApp(home: DebugScreen(source: DebugSource.fake)),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Decoded FF12'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(); // the mode-state stream delivers after the build

      expect(
        find.textContaining('Could not turn the previous stream off'),
        findsOneWidget,
      );
      expect(adapter.ccc, ['on ff11', 'FAIL off ff11']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('banner wording for the 0x80 refusal', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ModeFaultBanner(
              ModeFault(ModeFaultKind.otherStreamActive, 'other stream active'),
            ),
          ),
        ),
      );
      expect(find.textContaining('ATT 0x80'), findsOneWidget);
      expect(find.textContaining('other stream active'), findsOneWidget);
    });
  });

  group('decoded loss and link quality', () {
    testWidgets('shows cumulative and windowed loss plus RSSI and state', (
      tester,
    ) async {
      const stats = DecodedStats(
        hands: [
          DecodedHandStats(
            records: 90,
            missingFromTicks: 10,
            windowLoss: LossWindowStats(
              records: 45,
              missing: 5,
              spanUs: 5000000,
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DecodedStatsView(
              stats,
              selectedHand: 0,
              link: LinkStatus(
                state: BleConnectionState.connected,
                info: BleConnectionInfo(
                  mtu: 517,
                  rssi: -48,
                  connectionIntervalUs: 15000,
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        find.textContaining('loss 10.0% cumulative  10.0% last 5 s'),
        findsOneWidget,
      );
      expect(
        find.textContaining('link connected  RSSI -48 dBm  MTU 517  15.0 ms'),
        findsOneWidget,
      );
    });

    testWidgets('0 records is 0 %, and missing link or window data is n/a', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DecodedStatsView(
              DecodedStats(
                hands: [
                  DecodedHandStats(),
                  DecodedHandStats(records: 0, missingFromTicks: 7),
                ],
              ),
              selectedHand: 1,
            ),
          ),
        ),
      );

      expect(
        find.textContaining('loss 0.0% cumulative  - last 5 s'),
        findsOneWidget,
      );
      expect(
        find.textContaining('loss 100.0% cumulative  - last 5 s'),
        findsOneWidget,
      );
      expect(find.text('link n/a'), findsOneWidget);
    });

    testWidgets('per-bridge rows show link figures and decoded counters', (
      tester,
    ) async {
      const bridgeLeft = DecodedStats(
        hands: [
          DecodedHandStats(records: 90, missingFromTicks: 10, rateHz: 99),
          DecodedHandStats(),
        ],
      );
      const bridgeRight = DecodedStats(
        hands: [
          DecodedHandStats(),
          DecodedHandStats(records: 120, rateHz: 120),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  BridgeLinkTable([
                    BridgeLinkSnapshot(
                      bridgeId: 'bridge-left',
                      mode: StreamMode.decoded,
                      mtu: 247,
                      rssi: -48,
                      rateHz: [99, 0],
                      loss: [0.1, null],
                    ),
                    BridgeLinkSnapshot(
                      bridgeId: 'bridge-right',
                      mode: StreamMode.decoded,
                      mtu: 247,
                      rssi: -60,
                      rateHz: [0, 120],
                      loss: [null, 0],
                    ),
                  ]),
                  DecodedStatsView(
                    DecodedStats(
                      hands: [DecodedHandStats(), DecodedHandStats()],
                      byBridge: {
                        'bridge-left': bridgeLeft,
                        'bridge-right': bridgeRight,
                      },
                    ),
                    selectedHand: 0,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(
        find.textContaining(
          'bridge-left  decoded  MTU 247  RSSI -48 dBm  '
          'L 99.0/s 10.0%  R -',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('bridge-right  decoded  MTU 247  RSSI -60 dBm'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'bridge bridge-left  LEFT 90 rx  99.0 Hz  loss 10.0%',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('bridge bridge-right  RIGHT 120 rx  120.0 Hz'),
        findsOneWidget,
      );
    });

    testWidgets('a disconnected link drops stale RSSI', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DecodedStatsView(
              DecodedStats(hands: [DecodedHandStats()]),
              selectedHand: 0,
              link: LinkStatus(state: BleConnectionState.disconnected),
            ),
          ),
        ),
      );

      expect(
        find.textContaining('link disconnected  RSSI n/a'),
        findsOneWidget,
      );
      expect(find.textContaining('dBm'), findsNothing);
    });
  });

  group('6DoF viewer sources', () {
    Future<void> open(
      WidgetTester tester, {
      DebugPoses? poses,
      bool simulated = false,
      Quaternion? orientation,
    }) async {
      tall(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamModeProvider.overrideWith(RawModeNotifier.new),
            orientationProvider.overrideWith(
              (ref) =>
                  Stream.value(orientation ?? quaternionFromEuler(0, 0, 0)),
            ),
            streamStatsProvider.overrideWith(
              (ref) => Stream.value(
                const StreamStats(hands: [HandStats(), HandStats()]),
              ),
            ),
            if (poses != null)
              debugPosesProvider(DebugSource.fake)
                  .overrideWith((ref) => Stream.value(poses)),
          ],
          child: const MaterialApp(home: DebugScreen(source: DebugSource.fake)),
        ),
      );
      await tester.pump();
      if (simulated) {
        ProviderScope.containerOf(tester.element(find.byType(DebugScreen)))
            .read(debugTrackingSourceProvider.notifier)
            .set(DebugTrackingSource.simulated);
        await tester.pump();
      }
    }

    for (final source in ControllerPoseSource.values) {
      testWidgets('labels ${source.name} and reads position per hand', (
        tester,
      ) async {
        await open(tester, poses: _poses(source));

        expect(find.byType(ControllerPoseView), findsOneWidget);
        expect(find.textContaining('source ${source.name}'), findsNWidgets(2));
        if (source == ControllerPoseSource.orientationOnly) {
          expect(find.textContaining('position none'), findsWidgets);
          expect(
            find.textContaining('fallback: orientation only, no position'),
            findsOneWidget,
          );
        } else {
          expect(
            find.textContaining('position 0.123, -0.250, -0.300 m'),
            findsWidgets,
          );
        }
        expect(find.text('Tracking source'), findsOneWidget);
      });
    }

    testWidgets('reset orientation zeroes the viewer pose yaw', (tester) async {
      final raw = quaternionFromEuler(0.5, 0.2, -0.1);
      await open(tester, orientation: raw);

      final before = tester
          .widget<ControllerPoseView>(find.byType(ControllerPoseView))
          .pose
          .orientation;
      expect(eulerFromQuaternion(before).yawDeg, closeTo(28.6, 0.1));

      await tester.tap(find.text('Reset orientation'));
      await tester.pump();

      final after = tester
          .widget<ControllerPoseView>(find.byType(ControllerPoseView))
          .pose
          .orientation;
      expect(eulerFromQuaternion(after).yawDeg, closeTo(0, 0.1));
      expect(eulerFromQuaternion(after).pitchDeg, closeTo(11.5, 0.1));
    });

    testWidgets('the simulated source lifts 3DoF to a hand anchor', (
      tester,
    ) async {
      await open(tester, simulated: true);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('source handAnchor'), findsNWidgets(2));
      expect(find.textContaining('source orientationOnly'), findsNothing);
      expect(find.textContaining('m  source handAnchor'), findsNWidgets(2));
      expect(
        find.textContaining('fallback: orientation only, no position'),
        findsNothing,
      );
    });
  });
}
