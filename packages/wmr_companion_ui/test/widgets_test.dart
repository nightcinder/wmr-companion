import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_ui/wmr_companion_ui.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders the orientation cube', (tester) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 240,
          height: 240,
          child: OrientationView(orientation: Quaternion.identity()),
        ),
      ),
    );

    expect(find.byType(OrientationView), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  test('rotates actively and does not mutate its input', () {
    final q = Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2);
    final body = Vector3(1, 0, 0);

    final rotated = rotateOrientationVector(q, body);

    expect(rotated.x, closeTo(0, 1e-9));
    expect(rotated.z, closeTo(-1, 1e-9));
    // The shared cube corners must survive every paint unchanged.
    expect(body.x, 1);
    expect(body.z, 0);
  });

  testWidgets('renders link fields and a stream fault', (tester) async {
    await tester.pumpWidget(
      _host(
        LinkStatusView(
          const WmrLinkSnapshot(
            state: WmrConnectionState.ready,
            deviceId: 'bridge-1',
            mtu: 247,
            rssi: -55,
            connectionIntervalUs: 7500,
            phy: '2M',
            mode: StreamMode.batched,
            fault: WmrStreamModeFault(
              WmrStreamModeFaultKind.mtuTooSmall,
              'need 61',
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('link ready'), findsOneWidget);
    expect(find.textContaining('MTU 247'), findsOneWidget);
    expect(find.textContaining('RSSI -55 dBm'), findsOneWidget);
    expect(find.textContaining('7.5 ms'), findsOneWidget);
    expect(find.textContaining('fault mtuTooSmall: need 61'), findsOneWidget);
  });

  testWidgets('renders raw and decoded hand counters', (tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            const HandStatsView(
              hand: Hand.left,
              stats: WmrHandStats(frames: 12, sequenceGaps: 2, lastSequence: 9),
            ),
            const HandStatsView(
              hand: Hand.right,
              stats: WmrHandStats(
                records: 100,
                rateHz: 200,
                missingFromTicks: 4,
                periodTicks: 100000,
                dt: DtStats(p50: 0.01, p95: 0.02, max: 0.03),
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.textContaining('LEFT  frames 12'), findsOneWidget);
    expect(
      find.textContaining('LEFT  frames 12  records 0  rate -'),
      findsOneWidget,
    );
    expect(find.textContaining('missing (ticks) -'), findsOneWidget);
    expect(find.textContaining('loss - cumulative'), findsOneWidget);
    expect(find.textContaining('RIGHT  frames 0  records 100'), findsOneWidget);
    expect(find.textContaining('dt p50 10.00 ms'), findsOneWidget);
    expect(find.textContaining('nominal period 10.00 ms'), findsOneWidget);
  });

  testWidgets('renders gamepad sticks, triggers and buttons', (tester) async {
    await tester.pumpWidget(
      _host(
        const GamepadStateView(
          GamepadState(
            leftConnected: true,
            rightConnected: true,
            leftStick: [0.5, -0.25],
            rightTrigger: 0.75,
            buttons: {GamepadButton.a, GamepadButton.l1},
          ),
        ),
      ),
    );

    expect(find.textContaining('connected L true  R true'), findsOneWidget);
    expect(find.textContaining('sticks L [0.50, -0.25]'), findsOneWidget);
    expect(find.textContaining('triggers L 0.00  R 0.75'), findsOneWidget);
    expect(find.textContaining('buttons a, l1'), findsOneWidget);
  });
}
