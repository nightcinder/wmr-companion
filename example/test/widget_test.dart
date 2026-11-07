import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_example/main.dart';

void main() {
  testWidgets('shows the gamepad example', (tester) async {
    await tester.pumpWidget(const WmrExampleApp());
    await tester.pump();
    // Let the fake bridge tick and the facade publish a sample.
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('wmr_companion example'), findsOneWidget);
    expect(find.textContaining('Connection:'), findsOneWidget);
    expect(find.textContaining('Sticks: L ['), findsOneWidget);
    expect(find.textContaining('firmware fake-1.0.0'), findsOneWidget);
    expect(
      find.textContaining('features FF11 FF12 FF13 FF14 FF15 FF16 FF17'),
      findsOneWidget,
    );

    // Dispose the app so the fake bridge timer does not outlive the test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
