import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import 'package:wmr_core/domain/orientation.dart';

/// Draws a cube and its body axes rotated by [orientation], with a simple
/// perspective projection. X red, Y green, Z blue; the +Z face is shaded.
class OrientationPainter extends CustomPainter {
  OrientationPainter(this.orientation, {required this.edgeColor});

  final vm.Quaternion orientation;
  final Color edgeColor;

  static const double _cameraDistance = 5;
  static const double _halfSize = 0.7;

  static final List<vm.Vector3> _corners = [
    for (final x in [-1.0, 1.0])
      for (final y in [-1.0, 1.0])
        for (final z in [-1.0, 1.0]) vm.Vector3(x, y, z) * _halfSize,
  ];

  // Pairs of corner indices differing in exactly one coordinate.
  static final List<(int, int)> _edges = [
    for (var a = 0; a < 8; a++)
      for (final bit in [1, 2, 4])
        if (a & bit == 0) (a, a | bit),
  ];

  // Corners with z = +1, in drawing order around the face.
  static const List<int> _frontFace = [1, 3, 7, 5];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final focal = size.shortestSide * 1.6;

    Offset project(vm.Vector3 v) {
      final r = rotateVector(orientation, v);
      final depth = _cameraDistance - r.z;
      return center + Offset(focal * r.x / depth, -focal * r.y / depth);
    }

    final points = [for (final c in _corners) project(c)];

    final front = Path()
      ..addPolygon([for (final i in _frontFace) points[i]], true);
    canvas.drawPath(
      front,
      Paint()..color = Colors.blue.withValues(alpha: 0.18),
    );

    final edgePaint = Paint()
      ..color = edgeColor
      ..strokeWidth = 1.5;
    for (final (a, b) in _edges) {
      canvas.drawLine(points[a], points[b], edgePaint);
    }

    final origin = project(vm.Vector3.zero());
    const axisLength = 1.3;
    final axes = [
      (vm.Vector3(axisLength, 0, 0), Colors.red),
      (vm.Vector3(0, axisLength, 0), Colors.green),
      (vm.Vector3(0, 0, axisLength), Colors.blue),
    ];
    for (final (axis, color) in axes) {
      canvas.drawLine(
        origin,
        project(axis),
        Paint()
          ..color = color
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(OrientationPainter oldDelegate) =>
      oldDelegate.orientation != orientation ||
      oldDelegate.edgeColor != edgeColor;
}
