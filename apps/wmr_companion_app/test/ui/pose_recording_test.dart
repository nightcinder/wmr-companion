import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_screen.dart';
import 'package:wmr_companion_app/ui/debug/pose_recording_store.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/services/controller_service.dart';

import 'raw_mode_notifier.dart';

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Directory _tempStore(WidgetTester tester) {
  final directory = Directory.systemTemp.createTempSync('ony249-pose-');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

Future<void> _openDebugScreen(WidgetTester tester, Directory directory) async {
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
        poseRecordingStoreProvider.overrideWith(
          (ref) async => PoseRecordingStore(directory),
        ),
      ],
      child: const MaterialApp(home: DebugScreen(source: DebugSource.fake)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('committed fixture replays into the 6DoF viewer', (tester) async {
    final directory = _tempStore(tester);
    final fixture = [
      '../../packages/wmr_tracking/test/fixtures/pose_recording_v1.json',
      '../packages/wmr_tracking/test/fixtures/pose_recording_v1.json',
    ].map(File.new).firstWhere((file) => file.existsSync());
    File(
      '${directory.path}${Platform.pathSeparator}'
      'pose-20260101-000000.json',
    ).writeAsStringSync(fixture.readAsStringSync());

    await _openDebugScreen(tester, directory);

    await tester.tap(find.byKey(const ValueKey('pose-load-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('pose-20260101-000000.json'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('REPLAY 1 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Next sample'));
    await tester.pumpAndSettle();
    expect(find.textContaining('REPLAY 2 / 3'), findsOneWidget);
    expect(
      find.textContaining('position -0.180, -0.250, -0.350 m'),
      findsWidgets,
    );

    await tester.tap(find.byKey(const ValueKey('pose-replay-play')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpAndSettle();

    expect(find.textContaining('REPLAY 3 / 3'), findsOneWidget);
    expect(
      find.textContaining('position -0.300, -0.200, -0.350 m'),
      findsWidgets,
    );
  });

  testWidgets('record then replay keeps the recorded poses', (tester) async {
    final directory = _tempStore(tester);
    await _openDebugScreen(tester, directory);

    await tester.tap(find.byKey(const ValueKey('pose-record-button')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byKey(const ValueKey('pose-stop-button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('REPLAY '), findsOneWidget);
    final saved = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();
    expect(saved, hasLength(1));
  });
}
