import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/protocol/echo.dart';
import 'package:wmr_companion/protocol/wmr_fragment.dart';
import 'package:wmr_companion/services/echo_client.dart';
import 'package:wmr_companion/services/latency_recorder.dart';
import 'package:wmr_companion/ui/latency/latency_screen.dart';

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
}
