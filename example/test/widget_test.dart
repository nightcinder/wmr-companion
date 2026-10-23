import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_example/main.dart';

void main() {
  testWidgets('shows the gamepad example', (tester) async {
    await tester.pumpWidget(const WmrExampleApp());
    await tester.pump();

    expect(find.text('wmr_companion example'), findsOneWidget);
    expect(find.textContaining('Connection:'), findsOneWidget);

    // Dispose the app so the fake bridge timer does not outlive the test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
