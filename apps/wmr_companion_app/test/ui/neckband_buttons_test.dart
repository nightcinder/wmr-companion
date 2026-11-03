import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/ui/input/neckband_buttons.dart';

void main() {
  late FocusNode first;
  late FocusNode second;
  var firstPresses = 0;

  setUp(() {
    first = FocusNode(debugLabel: 'first');
    second = FocusNode(debugLabel: 'second');
    firstPresses = 0;
  });

  tearDown(() {
    first.dispose();
    second.dispose();
  });

  Widget harness({Widget? extra}) {
    final navigatorKey = GlobalKey<NavigatorState>();
    return MaterialApp(
      navigatorKey: navigatorKey,
      builder: (context, child) => NeckbandButtonNavigator(
        navigatorKey: navigatorKey,
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Column(
          children: [
            ?extra,
            FilledButton(
              key: const Key('first'),
              focusNode: first,
              onPressed: () => firstPresses++,
              child: const Text('First'),
            ),
            FilledButton(
              key: const Key('second'),
              focusNode: second,
              onPressed: () {},
              child: const Text('Second'),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('short Volume Down / Up moves focus forward and back', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    first.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pump();
    expect(second.hasFocus, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.pump();
    expect(first.hasFocus, isTrue);
  });

  testWidgets('holding Volume Down activates the focused control', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    first.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pump();

    expect(firstPresses, 1);
  });

  testWidgets('holding Volume Up goes back', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Second screen')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Second screen'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.pumpAndSettle();

    expect(find.text('Second screen'), findsNothing);
  });

  testWidgets('a focused text field keeps the rocker for volume', (
    tester,
  ) async {
    await tester.pumpWidget(harness(extra: const TextField(autofocus: true)));
    await tester.pump();
    final textFocus = FocusManager.instance.primaryFocus;
    expect(
      textFocus?.context?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, same(textFocus));
  });
}
