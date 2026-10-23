import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/echo.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/echo_client.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_core/services/latency_recorder.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/latency/latency_providers.dart';
import 'package:wmr_companion_app/ui/latency/latency_screen.dart';

void main() {
  testWidgets('report view shows the decoded figures per hand', (tester) async {
    final r = LatencyRecorder(
      started: DateTime(2026, 10, 22),
      originUs: 0,
      stream: 'decoded',
    )..markModeChanged();
    for (var i = 0; i < 20; i++) {
      r.addRecord(
        wmrHandLeft,
        i + 1,
        i * 5000,
        deviceTicks: i * 50000,
        espRxUs: i * 5000,
      );
    }
    final report = r.report(
      nowUs: 100000,
      link: const LatencyLink(mtu: 517, rssiStart: -55),
      counters: const {'incomplete_frames': 0, 'decoded_parse_errors': 2},
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LatencyReportView(report))),
    );
    expect(find.text('Stream: decoded'), findsOneWidget);
    expect(find.textContaining('MTU 517   RSSI -55 dBm'), findsOneWidget);
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('RIGHT'), findsNothing);
    expect(find.textContaining('inter-arrival ms  p50 5.0'), findsOneWidget);
    expect(find.textContaining('missing (ticks) 0'), findsOneWidget);
    expect(find.textContaining('delay above min ms'), findsOneWidget);
    expect(find.textContaining('mix two streams'), findsOneWidget);
    expect(
      find.text('During the run: decoded_parse_errors +2'),
      findsOneWidget,
    );
  });

  testWidgets('report view shows the round-trip distribution', (tester) async {
    final r = LatencyRecorder(
      started: DateTime(2026, 10, 22),
      originUs: 0,
      stream: 'batched',
    );
    for (var i = 1; i <= 20; i++) {
      r.addEcho(
        EchoSample(
          t1Us: i * 250000,
          t1DoneUs: i * 250000 + 100,
          t4Us: i * 250000 + 10300 + (i == 20 ? 14000 : 0),
          answer: EchoAnswer(
            pingId: i,
            rxTimeUs: 1000000 + i * 250000,
            turnaroundUs: 300,
            queueDepth: i == 3 ? 2 : 0,
          ),
        ),
      );
    }
    r.addEchoTimeout();
    final report = r.report(nowUs: 6000000);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LatencyReportView(report))),
    );
    expect(find.text('Round trip (FF15)'), findsOneWidget);
    expect(find.text('20 answered of 21  timeouts 1'), findsOneWidget);
    expect(
      find.textContaining('rtt ms  min 10.0  p50 10.0  p95 10.0'),
      findsOneWidget,
    );
    expect(find.textContaining('max 24.0'), findsOneWidget);
    expect(find.textContaining('queue depth max 2'), findsOneWidget);
  });

  testWidgets('no-stream report says so and shows no stream figures', (
    tester,
  ) async {
    final r = LatencyRecorder(
      started: DateTime(2026, 10, 22),
      originUs: 0,
      stream: 'none',
    );
    r.addEcho(
      EchoSample(
        t1Us: 250000,
        t1DoneUs: 250100,
        t4Us: 260300,
        answer: const EchoAnswer(
          pingId: 1,
          rxTimeUs: 1000000,
          turnaroundUs: 300,
          queueDepth: 0,
        ),
      ),
    );
    final report = r.report(nowUs: 500000, echoIntervalUs: 50000);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LatencyReportView(report))),
    );
    expect(find.text('Stream: no stream'), findsOneWidget);
    expect(find.textContaining('FF11, FF12 and FF14 were off'), findsOneWidget);
    expect(find.text('LEFT'), findsNothing);
    expect(find.text('RIGHT'), findsNothing);
    expect(find.text('Round trip (FF15)'), findsOneWidget);
  });

  testWidgets('stream selector applies a choice through the service', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('latency_screen');
    addTearDown(() => dir.deleteSync(recursive: true));
    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    final service = ControllerService(
      transport,
      fakeBridgeDeviceId,
      mode: StreamMode.decoded,
    );
    await service.start();
    FakeWmrBridge(transport);
    addTearDown(() async {
      await service.dispose();
      await transport.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          controllerServiceProvider(DebugSource.fake)
              .overrideWithValue(service),
          latencyInputProvider.overrideWithValue(
            (_) async => LatencyInput.fromService(service),
          ),
          latencyStoreProvider.overrideWith(
            (ref) => LatencyStore(
              Directory('${dir.path}${Platform.pathSeparator}latency'),
            ),
          ),
        ],
        child: const MaterialApp(home: LatencyScreen(source: DebugSource.fake)),
      ),
    );
    await tester.pump();

    for (final label in ['None', 'FF11 raw', 'FF12 decoded', 'FF14 batched']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('None'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(service.mode, StreamMode.none);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'None'))
          .selected,
      isTrue,
    );

    await tester.tap(find.text('FF11 raw'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(service.mode, StreamMode.raw);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'FF11 raw'))
          .selected,
      isTrue,
    );
    // Let the controller's first-run bookkeeping finish.
    await tester.pumpAndSettle();
  });
}
