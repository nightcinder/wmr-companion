import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion_app/app.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/sbs/stereo_sbs.dart';

void main() {
  Future<void> openApp(WidgetTester tester, Size size) async {
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
}
