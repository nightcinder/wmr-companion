import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/app.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/sbs/stereo_sbs.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

void main() {
  Pose headPose({
    double yawRight = 0,
    double pitchUp = 0,
    double x = 0,
    double y = 0,
    double z = 0,
  }) => Pose(
    translation: Vector3(x, y, z),
    rotation:
        Quaternion.axisAngle(Vector3(0, 1, 0), -yawRight) *
        Quaternion.axisAngle(Vector3(1, 0, 0), pitchUp),
  );

  Future<void> openApp(
    WidgetTester tester,
    Size size, {
    Pose? pose,
    Pose? origin,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final transport = UniversalBleTransport(
      adapter: FakeBleAdapter(),
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          appVersionProvider.overrideWith((ref) => '0.3.8+13'),
          if (pose != null)
            stereoHeadPoseProvider.overrideWith((ref) => Stream.value(pose)),
          if (origin != null)
            stereoHeadOriginProvider.overrideWith(() => _FixedOrigin(origin)),
        ],
        child: const WmrCompanionApp(),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  test('the aspect threshold starts at 32:9', () {
    expect(isSbsViewport(const Size(3840, 1080)), isTrue); // 3.56
    expect(isSbsViewport(const Size(3000, 1000)), isTrue); // exactly 3.0
    expect(isSbsViewport(const Size(1920, 1080)), isFalse);
    expect(isSbsViewport(const Size(0, 0)), isFalse);
  });

  testWidgets('a 3840x1080 viewport renders the UI in both eye halves', (
    tester,
  ) async {
    await openApp(tester, const Size(3840, 1080));

    expect(find.text('WMR Companion'), findsNWidgets(2));
    expect(find.byKey(const Key('connect-scan')), findsNWidgets(2));

    final titles = find.text('WMR Companion');
    expect(tester.getCenter(titles.first).dx, lessThan(1920));
    expect(tester.getCenter(titles.last).dx, greaterThan(1920));

    // Identical content: both halves show the same app bar action row.
    expect(find.byKey(const Key('toggle-sbs')), findsNWidgets(2));
    await close(tester);
  });

  testWidgets('a phone viewport renders a single pane', (tester) async {
    await openApp(tester, const Size(432, 960));

    expect(find.text('WMR Companion'), findsOneWidget);
    expect(find.byKey(const Key('connect-scan')), findsOneWidget);
    await close(tester);
  });

  testWidgets('the manual toggle forces SBS on and off', (tester) async {
    await openApp(tester, const Size(432, 960));
    expect(find.byKey(const Key('connect-scan')), findsOneWidget);

    await tester.tap(find.byKey(const Key('toggle-sbs')));
    await tester.pump();
    expect(find.byKey(const Key('connect-scan')), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('toggle-sbs')).first);
    await tester.pump();
    expect(find.byKey(const Key('connect-scan')), findsOneWidget);
    await close(tester);
  });

  testWidgets('the manual toggle turns SBS off on a 32:9 viewport', (
    tester,
  ) async {
    await openApp(tester, const Size(3840, 1080));
    expect(find.byKey(const Key('connect-scan')), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('toggle-sbs')).first);
    await tester.pump();
    expect(find.byKey(const Key('connect-scan')), findsOneWidget);
    await close(tester);
  });

  testWidgets('both eyes share the focused scan action in SBS', (tester) async {
    await openApp(tester, const Size(3840, 1080));

    final buttons = tester
        .widgetList<FilledButton>(find.byKey(const Key('connect-scan')))
        .toList();
    expect(buttons, hasLength(2));
    // One node shared by both halves, so both paint the focus ring.
    expect(buttons.first.focusNode, same(buttons.last.focusNode));
    expect(buttons.first.focusNode?.hasFocus, isTrue);
    await close(tester);
  });

  testWidgets('turning SBS off keeps the shared scan node focused', (
    tester,
  ) async {
    await openApp(tester, const Size(3840, 1080));

    await tester.tap(find.byKey(const Key('toggle-sbs')).first);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('connect-scan')), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('connect-scan')),
    );
    expect(button.focusNode?.hasFocus, isTrue);
    await close(tester);
  });

  testWidgets('D-pad traversal follows the Connect action order', (
    tester,
  ) async {
    await openApp(tester, const Size(3840, 1080));

    bool focused(String key) =>
        tester
            .widgetList<FilledButton>(find.byKey(Key(key)))
            .first
            .focusNode
            ?.hasFocus ??
        false;
    expect(focused('connect-scan'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focused('export-test-bundle'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focused('open-guided-bench'), isTrue);
    await close(tester);
  });

  testWidgets('Wi-Fi fields and the TLS switch stay identical in both eyes', (
    tester,
  ) async {
    await openApp(tester, const Size(3840, 1080));

    await tester.tap(find.text('Wi-Fi').first);
    await tester.pump();
    expect(find.byKey(const Key('wifi-host')), findsNWidgets(2));

    await tester.enterText(
      find.byKey(const Key('wifi-host')).first,
      '10.0.0.7',
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('wifi-host')),
        matching: find.text('10.0.0.7'),
      ),
      findsNWidgets(2),
    );

    await tester.tap(find.byKey(const Key('wifi-secure')).first);
    await tester.pump();
    expect(find.textContaining('cleartext over'), findsNothing);
    await close(tester);
  });

  testWidgets('scrolling one eye moves the other in step', (tester) async {
    // A short viewport forces the Connect list to overflow.
    await openApp(tester, const Size(3840, 200));

    double offset(int pane) => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView).at(pane),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;

    expect(offset(0), 0);
    expect(offset(1), 0);

    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump();

    expect(offset(0), greaterThan(0));
    expect(offset(1), offset(0));
    await close(tester);
  });

  testWidgets('a 32:9 bench shares one focused primary action', (tester) async {
    await openApp(tester, const Size(3840, 1080));

    await tester.tap(find.byKey(const Key('open-guided-bench')).first);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final starts = tester
        .widgetList<FilledButton>(find.byKey(const Key('bench-start')))
        .toList();
    expect(starts, hasLength(2));
    expect(starts.first.focusNode, same(starts.last.focusNode));
    expect(starts.first.focusNode?.hasFocus, isTrue);
    await close(tester);
  });

  group('head-pose counter-offset', () {
    const viewport = Size(3840, 1080);

    test('a zero pose leaves both panes centered', () {
      expect(
        stereoSbsCounterOffset(
          pose: Pose.identity,
          origin: Pose.identity,
          viewport: viewport,
        ),
        StereoHeadOffset.zero,
      );
      expect(
        stereoSbsCounterOffset(
          pose: null,
          origin: Pose.identity,
          viewport: viewport,
        ),
        StereoHeadOffset.zero,
      );
      expect(
        stereoSbsCounterOffset(
          pose: Pose.identity,
          origin: null,
          viewport: viewport,
        ),
        StereoHeadOffset.zero,
      );
    });

    test('yaw and pitch move the pane opposite the head', () {
      final offset = stereoSbsCounterOffset(
        pose: headPose(yawRight: 0.1, pitchUp: 0.05),
        origin: Pose.identity,
        viewport: viewport,
      );
      // Looking right moves the pane left; looking up moves it down.
      expect(offset.dx, lessThan(0));
      expect(offset.dy, greaterThan(0));
    });

    test('translation moves the pane opposite the head', () {
      final offset = stereoSbsCounterOffset(
        pose: headPose(x: 0.1, y: 0.05),
        origin: Pose.identity,
        viewport: viewport,
      );
      expect(offset.dx, lessThan(0));
      expect(offset.dy, greaterThan(0));
    });

    test('the offset is bounded to a fraction of an eye', () {
      final offset = stereoSbsCounterOffset(
        pose: headPose(yawRight: 3.0, pitchUp: 3.0, x: 5, y: 5),
        origin: Pose.identity,
        viewport: viewport,
      );
      expect(offset.dx.abs(), lessThanOrEqualTo(viewport.width / 2 * 0.20));
      expect(offset.dy.abs(), lessThanOrEqualTo(viewport.height * 0.20));
    });

    test('recenter keeps the current pose centered', () {
      final moved = headPose(yawRight: 0.2, x: 0.1);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(stereoHeadOriginProvider.notifier).recenter(moved);

      expect(container.read(stereoHeadOriginProvider), moved);
      expect(
        stereoSbsCounterOffset(
          pose: moved,
          origin: container.read(stereoHeadOriginProvider),
          viewport: viewport,
        ),
        StereoHeadOffset.zero,
      );
    });

    testWidgets('a non-zero pose shifts both eye panes', (tester) async {
      await openApp(
        tester,
        viewport,
        pose: headPose(yawRight: 0.1, pitchUp: 0.05),
        origin: Pose.identity,
      );

      final left = tester
          .widget<Transform>(find.byKey(const Key('sbs-eye-left')))
          .transform
          .getTranslation();
      final right = tester
          .widget<Transform>(find.byKey(const Key('sbs-eye-right')))
          .transform
          .getTranslation();

      expect(left.x, lessThan(0));
      expect(left.y, greaterThan(0));
      expect(right.x, left.x);
      expect(right.y, left.y);
      await close(tester);
    });

    testWidgets('a zero pose keeps both eye panes centered', (tester) async {
      await openApp(tester, viewport, pose: Pose.identity);

      for (final key in ['sbs-eye-left', 'sbs-eye-right']) {
        final translation = tester
            .widget<Transform>(find.byKey(Key(key)))
            .transform
            .getTranslation();
        expect(translation.x, 0);
        expect(translation.y, 0);
      }
      await close(tester);
    });

    testWidgets('the recenter action centers both panes', (tester) async {
      await openApp(
        tester,
        viewport,
        pose: headPose(yawRight: 0.1),
        origin: Pose.identity,
      );

      final before = tester
          .widget<Transform>(find.byKey(const Key('sbs-eye-left')))
          .transform
          .getTranslation();
      expect(before.x, lessThan(0));

      await tester.tap(find.byKey(const Key('sbs-recenter')).first);
      await tester.pump();

      final after = tester
          .widget<Transform>(find.byKey(const Key('sbs-eye-left')))
          .transform
          .getTranslation();
      expect(after.x, 0);
      expect(after.y, 0);
      await close(tester);
    });
  });
}

class _FixedOrigin extends StereoHeadOrigin {
  _FixedOrigin(this._pose);

  final Pose _pose;

  @override
  Pose? build() => _pose;
}
