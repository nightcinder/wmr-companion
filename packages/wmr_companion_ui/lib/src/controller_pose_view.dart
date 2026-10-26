import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;
import 'package:wmr_companion/wmr_companion.dart';

/// The raw [ControllerPoseSource] name shown in the source badge.
String controllerPoseSourceLabel(ControllerPoseSource source) => source.name;

/// Whether [source] is a fallback rather than an anchored position.
///
/// A head-relative position is a plausible guess, and an orientation-only pose
/// has no position at all; both are labelled in the widget so a host never
/// presents a fallback as a tracked controller.
bool controllerPoseSourceIsFallback(ControllerPoseSource source) =>
    source == ControllerPoseSource.headRelative ||
    source == ControllerPoseSource.orientationOnly;

/// A low-poly 3D viewer for a fused [ControllerPose].
///
/// Draws a WMR-style controller (halo ring plus handle) at the pose position
/// and orientation in the OpenXR tracking frame, plus a floor grid, a head
/// marker at [head] and a trail of recent positions. The position-source
/// badge names [ControllerPoseSource] so a fallback is never mistaken for an
/// anchored pose.
///
/// Give the widget a bounded box, for example with a [SizedBox] or an
/// [Expanded]. It has no controller or tracking-source dependency; the host
/// passes the latest facade pose.
class ControllerPoseView extends StatefulWidget {
  const ControllerPoseView({
    super.key,
    required this.pose,
    this.head,
    this.trailLength = 48,
    this.style,
  }) : assert(trailLength >= 0, 'trailLength must not be negative');

  final ControllerPose pose;

  /// Head pose in the same tracking frame as [pose]. When null the head
  /// marker sits at the frame origin. Only [Pose.translation] is used.
  final Pose? head;

  /// Maximum number of positions kept in the trail.
  final int trailLength;

  /// Style for the badge, position line and footer.
  final TextStyle? style;

  @override
  State<ControllerPoseView> createState() => _ControllerPoseViewState();
}

class _ControllerPoseViewState extends State<ControllerPoseView> {
  final List<Vector3> _trail = <Vector3>[];
  TrackedHand? _hand;

  @override
  void initState() {
    super.initState();
    _record(widget.pose);
  }

  @override
  void didUpdateWidget(covariant ControllerPoseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pose.hand != _hand) {
      _trail.clear();
    }
    _record(widget.pose);
  }

  void _record(ControllerPose pose) {
    _hand = pose.hand;
    final position = pose.position;
    if (position == null || widget.trailLength == 0) {
      _trail.clear();
      return;
    }
    if (_trail.isEmpty || (_trail.last - position).length > 1e-4) {
      _trail.add(Vector3.copy(position));
      final excess = _trail.length - widget.trailLength;
      if (excess > 0) {
        _trail.removeRange(0, excess);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final source = widget.pose.source;
    final fallback = controllerPoseSourceIsFallback(source);
    final position = widget.pose.position;

    final positionText = position == null
        ? 'position none'
        : 'position ${_metres(position.x)}, ${_metres(position.y)}, '
              '${_metres(position.z)} m';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _SourceBadge(
              source: source,
              style: widget.style,
              fallback: fallback,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${widget.pose.hand.name}  $positionText',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.style ?? textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ClipRect(
            child: CustomPaint(
              painter: ControllerPosePainter(
                pose: widget.pose,
                headPosition: widget.head?.translation ?? Vector3.zero(),
                trail: List<Vector3>.of(_trail),
                controllerColor: scheme.primary,
                trailColor: scheme.secondary,
                headColor: scheme.tertiary,
                gridColor: scheme.onSurface.withValues(alpha: 0.18),
              ),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'OpenXR frame  +X right  +Y up  -Z forward',
          style: widget.style ?? textTheme.labelSmall,
        ),
        if (fallback)
          Text(
            switch (source) {
              ControllerPoseSource.headRelative =>
                'fallback: head-relative position',
              ControllerPoseSource.orientationOnly =>
                'fallback: orientation only, no position',
              _ => '',
            },
            style: (widget.style ?? textTheme.labelSmall)?.copyWith(
              color: scheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        Wrap(
          spacing: 12,
          children: [
            _LegendItem(color: scheme.primary, label: 'controller'),
            _LegendItem(color: scheme.tertiary, label: 'head'),
            _LegendItem(color: scheme.secondary, label: 'trail'),
          ],
        ),
      ],
    );
  }
}

String _metres(double value) {
  final text = value.toStringAsFixed(3);
  return text == '-0.000' ? '0.000' : text;
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({
    required this.source,
    required this.fallback,
    this.style,
  });

  final ControllerPoseSource source;
  final bool fallback;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: fallback ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        controllerPoseSourceLabel(source),
        style: (style ?? Theme.of(context).textTheme.labelSmall)?.copyWith(
          color: fallback
              ? scheme.onErrorContainer
              : scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

/// Paints [pose] as a low-poly ring-and-handle controller in the OpenXR
/// tracking frame.
///
/// The camera basis is fixed, the scene is fitted to the head, controller and
/// trail, and mesh faces are sorted back to front so the painter is
/// deterministic and has no scene state of its own.
class ControllerPosePainter extends CustomPainter {
  ControllerPosePainter({
    required this.pose,
    Vector3? headPosition,
    List<Vector3> trail = const <Vector3>[],
    this.controllerColor = const Color(0xFF90CAF9),
    this.trailColor = const Color(0xFFFFB74D),
    this.headColor = const Color(0xFF81C784),
    this.gridColor = const Color(0x33FFFFFF),
  }) : headPosition = Vector3.copy(headPosition ?? Vector3.zero()),
       trail = <Vector3>[for (final point in trail) Vector3.copy(point)];

  final ControllerPose pose;
  final Vector3 headPosition;
  final List<Vector3> trail;
  final Color controllerColor;
  final Color trailColor;
  final Color headColor;
  final Color gridColor;

  /// From the scene centre towards the camera.
  static final Vector3 _eyeDirection = Vector3(0.55, 0.34, 1.0).normalized();
  static final Vector3 _camRight = Vector3(
    0,
    1,
    0,
  ).cross(_eyeDirection).normalized();
  static final Vector3 _camUp = _eyeDirection.cross(_camRight).normalized();
  static final Vector3 _light = Vector3(-0.38, 0.82, 0.55);

  static const double _majorRadius = 0.058;
  static const double _tubeRadius = 0.011;
  static const double _handleTop = -0.004;
  static const double _handleBottom = -0.148;
  static const double _handleTopRadius = 0.021;
  static const double _handleBottomRadius = 0.016;

  static final List<List<Vector3>> _mesh = _buildMesh();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.clipRect(Offset.zero & size);

    final head = headPosition;
    final fallbackPosition =
        head +
        Vector3(pose.hand == TrackedHand.left ? -0.20 : 0.20, -0.16, -0.36);
    final position = pose.position ?? fallbackPosition;
    final ghost = pose.position == null;

    final sceneCentre = (head + position) * 0.5;

    var extent = 0.16;
    void include(Vector3 world) {
      final offset = world - sceneCentre;
      extent = math.max(extent, offset.dot(_camRight).abs());
      extent = math.max(extent, offset.dot(_camUp).abs());
    }

    include(head);
    include(position);
    for (final point in trail) {
      include(point);
    }
    extent += 0.10;

    final scale = size.shortestSide * 0.42 / extent;
    final cameraDistance = extent * 4 + 0.5;
    final centre = size.center(Offset.zero);

    Vector3 view(Vector3 world) {
      final offset = world - sceneCentre;
      return Vector3(
        offset.dot(_camRight),
        offset.dot(_camUp),
        cameraDistance - offset.dot(_eyeDirection),
      );
    }

    Offset projectView(Vector3 v) {
      final depth = math.max(v.z, 0.05);
      final factor = scale * cameraDistance / depth;
      return centre + Offset(v.x * factor, -v.y * factor);
    }

    Offset project(Vector3 world) => projectView(view(world));

    _paintGrid(canvas, head, project);
    _paintHeadMarker(canvas, head, project, scale);
    _paintTrail(canvas, project);

    final faces = <_ProjectedFace>[];
    for (final meshFace in _mesh) {
      final world = <Vector3>[
        for (final local in meshFace)
          position + _rotate(pose.orientation, local),
      ];
      final projected = <Offset>[for (final point in world) project(point)];
      var depth = 0.0;
      for (final point in world) {
        depth += view(point).z;
      }
      depth /= world.length;
      final normal = (world[1] - world[0]).cross(world[2] - world[0]);
      if (normal.length2 > 0) normal.normalize();
      final shade =
          0.45 + 0.55 * normal.dot(_light).abs().clamp(0.0, 1.0).toDouble();
      faces.add(
        _ProjectedFace(
          points: projected,
          depth: depth,
          color: Color.lerp(
            Colors.black,
            controllerColor,
            shade,
          )!.withValues(alpha: ghost ? 0.45 : 1.0),
        ),
      );
    }
    faces.sort((a, b) => b.depth.compareTo(a.depth));

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = controllerColor.withValues(alpha: ghost ? 0.35 : 0.65);
    for (final face in faces) {
      final path = Path()..addPolygon(face.points, true);
      canvas.drawPath(path, Paint()..color = face.color);
      canvas.drawPath(path, outline);
    }
  }

  void _paintGrid(
    Canvas canvas,
    Vector3 head,
    Offset Function(Vector3) project,
  ) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final axisX = Paint()
      ..color = const Color(0x66E57373)
      ..strokeWidth = 1.2;
    final axisZ = Paint()
      ..color = const Color(0x6664B5F6)
      ..strokeWidth = 1.2;

    const half = 0.8;
    const step = 0.2;
    for (var i = -4; i <= 4; i++) {
      final offset = i * step;
      canvas.drawLine(
        project(Vector3(head.x - half, 0, head.z + offset)),
        project(Vector3(head.x + half, 0, head.z + offset)),
        i == 0 ? axisX : grid,
      );
      canvas.drawLine(
        project(Vector3(head.x + offset, 0, head.z - half)),
        project(Vector3(head.x + offset, 0, head.z + half)),
        i == 0 ? axisZ : grid,
      );
    }
  }

  void _paintHeadMarker(
    Canvas canvas,
    Vector3 head,
    Offset Function(Vector3) project,
    double scale,
  ) {
    final centre = project(head);
    final radius = math.max(4.0, scale * 0.035);
    canvas.drawCircle(
      centre,
      radius,
      Paint()..color = headColor.withValues(alpha: 0.20),
    );
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = headColor,
    );
    canvas.drawCircle(centre, radius * 0.28, Paint()..color = headColor);
    canvas.drawLine(
      project(head),
      project(Vector3(head.x, 0, head.z)),
      Paint()
        ..color = headColor.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
  }

  void _paintTrail(Canvas canvas, Offset Function(Vector3) project) {
    if (trail.length < 2) return;
    final path = Path()
      ..moveTo(project(trail.first).dx, project(trail.first).dy);
    for (final point in trail.skip(1)) {
      final offset = project(point);
      path.lineTo(offset.dx, offset.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = trailColor.withValues(alpha: 0.75),
    );
  }

  static Vector3 _rotate(Quaternion orientation, Vector3 body) =>
      orientation.asRotationMatrix().transformed(body);

  static List<List<Vector3>> _buildMesh() {
    final faces = <List<Vector3>>[];

    const majorSegments = 16;
    const minorSegments = 6;
    Vector3 torusPoint(int major, int minor) {
      final theta = 2 * math.pi * major / majorSegments;
      final phi = 2 * math.pi * minor / minorSegments;
      final radial = Vector3(math.cos(theta), 0, math.sin(theta));
      return radial * _majorRadius +
          radial * (_tubeRadius * math.cos(phi)) +
          Vector3(0, _tubeRadius * math.sin(phi), 0) +
          Vector3(0, 0.004, 0.008);
    }

    for (var i = 0; i < majorSegments; i++) {
      for (var j = 0; j < minorSegments; j++) {
        faces.add([
          torusPoint(i, j),
          torusPoint(i + 1, j),
          torusPoint(i + 1, j + 1),
          torusPoint(i, j + 1),
        ]);
      }
    }

    const handleSegments = 8;
    Vector3 handlePoint(int segment, {required bool top}) {
      final theta = 2 * math.pi * segment / handleSegments;
      final radius = top ? _handleTopRadius : _handleBottomRadius;
      return Vector3(
        math.cos(theta) * radius,
        top ? _handleTop : _handleBottom,
        math.sin(theta) * radius + 0.012,
      );
    }

    for (var i = 0; i < handleSegments; i++) {
      faces.add([
        handlePoint(i, top: true),
        handlePoint(i + 1, top: true),
        handlePoint(i + 1, top: false),
        handlePoint(i, top: false),
      ]);
    }

    final topCentre = Vector3(0, _handleTop, 0.012);
    final bottomCentre = Vector3(0, _handleBottom, 0.012);
    for (var i = 0; i < handleSegments; i++) {
      faces.add([
        topCentre,
        handlePoint(i, top: true),
        handlePoint(i + 1, top: true),
      ]);
      faces.add([
        bottomCentre,
        handlePoint(i + 1, top: false),
        handlePoint(i, top: false),
      ]);
    }

    return faces;
  }

  @override
  bool shouldRepaint(ControllerPosePainter oldDelegate) =>
      oldDelegate.pose != pose ||
      oldDelegate.pose.position != pose.position ||
      oldDelegate.pose.orientation != pose.orientation ||
      oldDelegate.headPosition != headPosition ||
      oldDelegate.trail.length != trail.length ||
      (trail.isNotEmpty && oldDelegate.trail.last != trail.last) ||
      oldDelegate.controllerColor != controllerColor ||
      oldDelegate.trailColor != trailColor ||
      oldDelegate.headColor != headColor ||
      oldDelegate.gridColor != gridColor;
}

class _ProjectedFace {
  const _ProjectedFace({
    required this.points,
    required this.depth,
    required this.color,
  });

  final List<Offset> points;
  final double depth;
  final Color color;
}
