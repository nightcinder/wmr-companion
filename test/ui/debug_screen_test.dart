import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/orientation.dart';
import 'package:wmr_companion/services/controller_service.dart';
import 'package:wmr_companion/ui/debug/debug_providers.dart';
import 'package:wmr_companion/ui/debug/debug_screen.dart';

void main() {
  testWidgets('shows orientation, resets yaw and shows stream stats', (
    tester,
  ) async {
    final q = quaternionFromEuler(0.5, 0.2, -0.1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
        child: const MaterialApp(home: DebugScreen()),
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
}
