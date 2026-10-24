import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_screen.dart';
import 'package:wmr_companion_app/ui/latency/latency_screen.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/latency_recorder.dart';

void main() {
  const kinds = {
    'bridge-left': BridgeTransportKind.ble,
    'bridge-right': BridgeTransportKind.wifi,
  };

  testWidgets('debug bridge table labels each bridge by transport', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BridgeLinkTable([
            BridgeLinkSnapshot(
              bridgeId: 'bridge-left',
              mode: StreamMode.raw,
              mtu: 247,
            ),
            BridgeLinkSnapshot(
              bridgeId: 'bridge-right',
              mode: StreamMode.raw,
              mtu: 4096,
            ),
          ], transportKinds: kinds),
        ),
      ),
    );

    expect(
      find.textContaining('BLE  bridge-left  raw  MTU 247'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Wi-Fi  bridge-right  raw  MTU 4096'),
      findsOneWidget,
    );
  });

  testWidgets('decoded per-bridge rows label each bridge by transport', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DecodedStatsView(
              DecodedStats(
                hands: [DecodedHandStats(), DecodedHandStats()],
                byBridge: {
                  'bridge-left': DecodedStats(
                    hands: [DecodedHandStats(records: 90), DecodedHandStats()],
                  ),
                  'bridge-right': DecodedStats(
                    hands: [DecodedHandStats(), DecodedHandStats(records: 120)],
                  ),
                },
              ),
              selectedHand: 0,
              transportKinds: kinds,
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('BLE  bridge bridge-left'), findsOneWidget);
    expect(find.textContaining('Wi-Fi  bridge bridge-right'), findsOneWidget);
  });

  testWidgets('latency report labels each bridge by transport', (tester) async {
    final recorder = LatencyRecorder(
      started: DateTime(2026, 10, 24),
      originUs: 0,
      stream: 'decoded',
    );
    for (var i = 1; i <= 3; i++) {
      recorder.addRecord(
        wmrHandLeft,
        i,
        i * 5000,
        deviceTicks: i * 50000,
        espRxUs: i * 5000,
        bridgeId: 'bridge-left',
      );
      recorder.addRecord(
        wmrHandRight,
        i,
        i * 5000,
        deviceTicks: i * 50000,
        espRxUs: i * 5000,
        bridgeId: 'bridge-right',
      );
    }
    final report = recorder.report(
      nowUs: 20000,
      links: const {
        'bridge-left': LatencyLink(mtu: 247),
        'bridge-right': LatencyLink(mtu: 4096),
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LatencyReportView(report, transportKinds: kinds),
          ),
        ),
      ),
    );

    expect(
      find.textContaining('BLE  bridge bridge-left   MTU 247'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Wi-Fi  bridge bridge-right   MTU 4096'),
      findsOneWidget,
    );
    expect(find.text('  BLE bridge bridge-left'), findsOneWidget);
    expect(find.text('  Wi-Fi bridge bridge-right'), findsOneWidget);
  });
}
