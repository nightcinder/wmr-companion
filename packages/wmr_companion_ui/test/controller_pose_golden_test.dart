import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_ui/wmr_companion_ui.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(
        child: SizedBox(width: 360, height: 460, child: child),
      ),
    ),
  ),
);

ControllerPose _pose(
  ControllerPoseSource source,
  Vector3? position,
  int hostTimeNs,
) => ControllerPose(
  hand: TrackedHand.right,
  hostTimeNs: hostTimeNs,
  orientation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.6),
  position: position,
  source: source,
  confidence: TrackingConfidence.high,
);

Future<void> _pumpTrail(
  WidgetTester tester,
  ControllerPoseSource source,
) async {
  final positions = source == ControllerPoseSource.orientationOnly
      ? <Vector3?>[null, null, null]
      : <Vector3?>[
          Vector3(0.10, -0.25, -0.30),
          Vector3(0.18, -0.22, -0.34),
          Vector3(0.24, -0.18, -0.40),
        ];
  for (var i = 0; i < positions.length; i++) {
    await tester.pumpWidget(
      _host(
        ControllerPoseView(
          pose: _pose(source, positions[i], 1000000 + i * 10000000),
          head: Pose(
            translation: Vector3.zero(),
            rotation: Quaternion.identity(),
          ),
        ),
      ),
    );
  }
}

void main() {
  setUp(() {
    // A fixed surface keeps the golden independent of the host window.
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  for (final source in ControllerPoseSource.values) {
    testWidgets('golden ${source.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 460));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpTrail(tester, source);

      await expectLater(
        find.byType(ControllerPoseView),
        matchesGoldenFile('goldens/controller_pose_${source.name}.png'),
      );
    });
  }
}
