import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_companion_ui/wmr_companion_ui.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_screen.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';

import 'raw_mode_notifier.dart';

const _vendorChoices = [
  DebugTrackingSource.androidXr,
  DebugTrackingSource.viture,
  DebugTrackingSource.xreal,
];

/// Android XR, VITURE and XREAL all go through a platform channel.
const _vendorChannels = [
  'wmr_tracking_android_xr/methods',
  'wmr_tracking_viture/methods',
  'wmr_tracking_xreal/methods',
];

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

Future<void> open(
  WidgetTester tester, {
  DebugTrackingSourceFactory? factory,
  TrackingSourceSelector? selector,
}) async {
  tall(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamModeProvider.overrideWith(RawModeNotifier.new),
        orientationProvider.overrideWith(
          (ref) => Stream.value(Quaternion.identity()),
        ),
        streamStatsProvider.overrideWith(
          (ref) => Stream.value(
            const StreamStats(hands: [HandStats(), HandStats()]),
          ),
        ),
        if (factory != null)
          debugTrackingSourceFactoryProvider.overrideWithValue(factory),
        if (selector != null)
          debugTrackingSelectorProvider.overrideWithValue(selector),
      ],
      child: const MaterialApp(home: DebugScreen(source: DebugSource.fake)),
    ),
  );
  await tester.pump();
}

void select(WidgetTester tester, DebugTrackingSource choice) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(DebugScreen)),
  );
  container.read(debugTrackingSourceProvider.notifier).set(choice);
}

TrackingFrame _handFrame(int timeNs) {
  final head = Pose(
    translation: Vector3(0, 1.6, 0),
    rotation: Quaternion.identity(),
  );
  Pose palm(double x) => Pose(
    translation: Vector3(x, -0.25, -0.35),
    rotation: Quaternion.identity(),
  );
  return TrackingFrame(
    timeNs: timeNs,
    hostTimeNs: timeNs,
    head: TrackedPose(pose: head),
    leftHand: HandPose(
      hand: TrackedHand.left,
      palm: TrackedPose(pose: palm(-0.18)),
    ),
    rightHand: HandPose(
      hand: TrackedHand.right,
      palm: TrackedPose(pose: palm(0.18)),
    ),
  );
}

class _FixedDetector implements GlassesDetector {
  const _FixedDetector(this.detection);

  final GlassesDetection detection;

  @override
  Future<GlassesDetection> detect() async => detection;
}

class _CountingDetector implements GlassesDetector {
  int calls = 0;

  @override
  Future<GlassesDetection> detect() async {
    calls++;
    return GlassesDetection.none;
  }
}

class _DeferredDetector implements GlassesDetector {
  final completer = Completer<GlassesDetection>();

  @override
  Future<GlassesDetection> detect() => completer.future;
}

void main() {
  test('the default factory returns null for every vendor flag off without '
      'touching a platform channel', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <MethodCall>[];
    for (final channel in _vendorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
            calls.add(call);
            return null;
          });
    }
    addTearDown(() {
      for (final channel in _vendorChannels) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(channel), null);
      }
    });

    for (final choice in _vendorChoices) {
      expect(choice.buildFlag, isNotNull);
      expect(await createDebugTrackingSource(choice), isNull);
    }
    expect(calls, isEmpty);
  });

  testWidgets('the selector offers None, Simulated and the three vendors', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('tracking-source-selector')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final choice in DebugTrackingSource.values) {
      expect(find.text(choice.label), findsWidgets);
    }
    await close(tester);
  });

  testWidgets('Auto (USB) attaches the natively detected vendor source', (
    tester,
  ) async {
    FakeTrackingSource? source;
    await open(
      tester,
      selector: TrackingSourceSelector(
        detector: const _FixedDetector(
          GlassesDetection(
            vendor: GlassesVendor.viture,
            host: GlassesHost.neckband,
          ),
        ),
        flags: const TrackingSourceFlags(viture: true),
        vitureSource: () async => source = FakeTrackingSource(),
      ),
    );

    select(tester, DebugTrackingSource.auto);
    await settle(tester);

    expect(source?.started, isTrue);
    expect(find.textContaining('Attached viture tracking'), findsOneWidget);

    source!.addFrame(_handFrame(1));
    await settle(tester);
    expect(find.textContaining('source handAnchor'), findsNWidgets(2));
    await close(tester);
  });

  testWidgets('Auto (USB) reports when no glasses are detected', (
    tester,
  ) async {
    await open(
      tester,
      selector: TrackingSourceSelector(
        detector: const _FixedDetector(GlassesDetection.none),
        flags: const TrackingSourceFlags(viture: true),
      ),
    );

    select(tester, DebugTrackingSource.auto);
    await settle(tester);

    expect(
      find.textContaining(
        'No VITURE, XREAL or Android XR glasses were detected',
      ),
      findsOneWidget,
    );
    await close(tester);
  });

  testWidgets('a flag-off build never probes the neckband detector', (
    tester,
  ) async {
    final detector = _CountingDetector();
    await open(
      tester,
      selector: TrackingSourceSelector(
        detector: detector,
        flags: const TrackingSourceFlags(),
      ),
    );
    await settle(tester);

    expect(detector.calls, 0);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DebugScreen)),
    );
    expect(
      container.read(debugTrackingSourceProvider).choice,
      DebugTrackingSource.none,
    );
    await close(tester);
  });

  testWidgets('a manual selection made during the neckband probe wins', (
    tester,
  ) async {
    final detector = _DeferredDetector();
    var vitureCreated = false;
    await open(
      tester,
      selector: TrackingSourceSelector(
        detector: detector,
        flags: const TrackingSourceFlags(viture: true),
        vitureSource: () async {
          vitureCreated = true;
          return FakeTrackingSource();
        },
      ),
    );

    select(tester, DebugTrackingSource.simulated);
    await settle(tester);
    detector.completer.complete(
      const GlassesDetection(
        vendor: GlassesVendor.viture,
        host: GlassesHost.neckband,
      ),
    );
    await settle(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DebugScreen)),
    );
    expect(
      container.read(debugTrackingSourceProvider).choice,
      DebugTrackingSource.simulated,
    );
    expect(vitureCreated, isFalse);
    await close(tester);
  });

  for (final choice in _vendorChoices) {
    testWidgets('${choice.label} is created, attached and feeds the viewer', (
      tester,
    ) async {
      DebugTrackingSource? created;
      FakeTrackingSource? source;
      await open(
        tester,
        factory: (choice) async {
          created = choice;
          return source = FakeTrackingSource();
        },
      );

      select(tester, choice);
      await settle(tester);

      expect(created, choice);
      expect(source?.started, isTrue);
      expect(
        find.textContaining('${choice.label} tracking attached'),
        findsOneWidget,
      );

      // A frame from the attached source must lift the viewer to a hand
      // anchor, proving it reaches SixDofFuser, not just the status text.
      source!.addFrame(_handFrame(1));
      await settle(tester);
      expect(find.textContaining('source handAnchor'), findsNWidgets(2));
      await close(tester);
    });

    testWidgets('${choice.label} shows a typed unavailable without crashing', (
      tester,
    ) async {
      await open(
        tester,
        factory: (choice) async => throw const TrackingException(
          TrackingExceptionKind.unavailable,
          'UnityPlayer is not linked in this build',
        ),
      );

      select(tester, choice);
      await settle(tester);

      expect(
        find.textContaining('TrackingException(unavailable)'),
        findsOneWidget,
      );
      expect(
        find.textContaining('UnityPlayer is not linked in this build'),
        findsOneWidget,
      );
      expect(find.byType(ControllerPoseView), findsOneWidget);
      await close(tester);
    });

    testWidgets('${choice.label} reports its dart-define when disabled', (
      tester,
    ) async {
      await open(tester, factory: (choice) async => null);

      select(tester, choice);
      await settle(tester);

      expect(
        find.textContaining('${choice.label} is off: rebuild with'),
        findsOneWidget,
      );
      expect(
        find.textContaining('--dart-define=${choice.buildFlag}=true'),
        findsOneWidget,
      );
      await close(tester);
    });
  }

  testWidgets('switching sources stops and disposes the previous one', (
    tester,
  ) async {
    final sources = <FakeTrackingSource>[];
    await open(
      tester,
      factory: (choice) async {
        final source = FakeTrackingSource();
        sources.add(source);
        return source;
      },
    );

    select(tester, DebugTrackingSource.androidXr);
    await settle(tester);
    expect(sources, hasLength(1));

    select(tester, DebugTrackingSource.viture);
    await settle(tester);

    expect(sources, hasLength(2));
    expect(sources.first.started, isFalse);
    expect(sources.first.disposed, isTrue);
    expect(sources.last.started, isTrue);
    await close(tester);
  });

  testWidgets('Simulated attaches the fake trajectory', (tester) async {
    await open(tester);
    select(tester, DebugTrackingSource.simulated);
    await settle(tester);

    expect(
      find.textContaining('FakeTrackingSource trajectory'),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('source handAnchor'), findsNWidgets(2));
    await close(tester);
  });
}
