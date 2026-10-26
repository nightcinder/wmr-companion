import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_ui/wmr_companion_ui.dart';

const _boundaryKey = ValueKey('pose-boundary');

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(
        key: _boundaryKey,
        child: SizedBox(width: 360, height: 460, child: child),
      ),
    ),
  ),
);

ControllerPose _pose({
  ControllerPoseSource source = ControllerPoseSource.runtimeController,
  Vector3? position,
  TrackedHand hand = TrackedHand.right,
  int hostTimeNs = 1000000,
  Quaternion? orientation,
}) => ControllerPose(
  hand: hand,
  hostTimeNs: hostTimeNs,
  orientation: orientation ?? Quaternion.axisAngle(Vector3(0, 1, 0), 0.6),
  position: position,
  source: source,
  confidence: TrackingConfidence.high,
);

Future<Uint8List> _capture(WidgetTester tester) async {
  final bytes = await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_boundaryKey),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

ControllerPosePainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .whereType<ControllerPosePainter>()
    .single;

void main() {
  testWidgets('renders every source state with a labelled badge', (
    tester,
  ) async {
    const cases = <(ControllerPoseSource, String?, String)>[
      (
        ControllerPoseSource.runtimeController,
        null,
        'position 0.200, -0.250, -0.300 m',
      ),
      (
        ControllerPoseSource.handAnchor,
        null,
        'position 0.200, -0.250, -0.300 m',
      ),
      (
        ControllerPoseSource.headRelative,
        'fallback: head-relative position',
        'position 0.200, -0.250, -0.300 m',
      ),
      (
        ControllerPoseSource.orientationOnly,
        'fallback: orientation only, no position',
        'position none',
      ),
    ];

    for (final (source, fallback, position) in cases) {
      await tester.pumpWidget(
        _host(
          ControllerPoseView(
            pose: _pose(
              source: source,
              position: source == ControllerPoseSource.orientationOnly
                  ? null
                  : Vector3(0.2, -0.25, -0.3),
            ),
          ),
        ),
      );

      expect(find.text(source.name), findsOneWidget, reason: source.name);
      expect(
        find.textContaining(position),
        findsOneWidget,
        reason: source.name,
      );
      expect(
        find.textContaining('fallback:'),
        fallback == null ? findsNothing : findsOneWidget,
        reason: source.name,
      );
      if (fallback != null) {
        expect(find.text(fallback), findsOneWidget);
      }
      expect(_painter(tester), isA<ControllerPosePainter>());
    }
  });

  testWidgets('trail keeps recent positions and resets on hand change', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ControllerPoseView(pose: _pose(position: Vector3(0.1, -0.2, -0.3))),
      ),
    );
    expect(_painter(tester).trail, hasLength(1));

    await tester.pumpWidget(
      _host(
        ControllerPoseView(pose: _pose(position: Vector3(0.2, -0.2, -0.3))),
      ),
    );
    expect(_painter(tester).trail, hasLength(2));

    await tester.pumpWidget(
      _host(
        ControllerPoseView(
          pose: _pose(
            position: Vector3(0.2, -0.2, -0.3),
            hand: TrackedHand.left,
          ),
        ),
      ),
    );
    expect(_painter(tester).trail, hasLength(1));
  });

  testWidgets('orientation-only pose has no stale trail', (tester) async {
    await tester.pumpWidget(
      _host(
        ControllerPoseView(pose: _pose(position: Vector3(0.1, -0.2, -0.3))),
      ),
    );
    expect(_painter(tester).trail, hasLength(1));

    await tester.pumpWidget(
      _host(
        ControllerPoseView(
          pose: _pose(
            source: ControllerPoseSource.orientationOnly,
            position: null,
          ),
        ),
      ),
    );
    expect(_painter(tester).trail, isEmpty);
  });

  testWidgets('orientation rotates the mesh and painting is deterministic', (
    tester,
  ) async {
    final position = Vector3(0.2, -0.25, -0.3);
    Widget view(Quaternion orientation) => _host(
      ControllerPoseView(
        pose: _pose(position: position, orientation: orientation),
      ),
    );

    await tester.pumpWidget(view(Quaternion.identity()));
    final first = await _capture(tester);
    await tester.pumpWidget(view(Quaternion.identity()));
    expect(await _capture(tester), orderedEquals(first));

    await tester.pumpWidget(view(Quaternion.axisAngle(Vector3(0, 1, 0), 1.4)));
    expect(await _capture(tester), isNot(orderedEquals(first)));
  });

  test('fallback sources are labelled', () {
    expect(
      controllerPoseSourceLabel(ControllerPoseSource.handAnchor),
      'handAnchor',
    );
    expect(
      controllerPoseSourceIsFallback(ControllerPoseSource.handAnchor),
      isFalse,
    );
    expect(
      controllerPoseSourceIsFallback(ControllerPoseSource.runtimeController),
      isFalse,
    );
    expect(
      controllerPoseSourceIsFallback(ControllerPoseSource.headRelative),
      isTrue,
    );
    expect(
      controllerPoseSourceIsFallback(ControllerPoseSource.orientationOnly),
      isTrue,
    );
  });
}
