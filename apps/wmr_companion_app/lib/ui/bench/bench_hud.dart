import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../debug/debug_providers.dart';
import 'bench_tracking.dart';

/// Live hand-joint skeleton and head-pose indicator shown on the bench page.
///
/// The VITURE Unity runtime draws hand tracking itself and suppresses
/// SpaceWalker's pointer, so the bench needs its own preview: otherwise the
/// tester sees no hands after tapping Run and cannot tell a 0DoF run from a
/// 6DoF one.
class BenchTrackingHud extends ConsumerStatefulWidget {
  const BenchTrackingHud({super.key});

  @override
  ConsumerState<BenchTrackingHud> createState() => _BenchTrackingHudState();
}

class _BenchTrackingHudState extends ConsumerState<BenchTrackingHud> {
  final BenchHeadMotionTracker _head = BenchHeadMotionTracker();
  DebugPoses? _last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poses = ref.watch(benchLivePosesProvider).value;
    final current = poses ?? const DebugPoses();
    // Each new source sample feeds the head travel window exactly once.
    if (!identical(current, _last)) {
      _last = current;
      _head.add(current.head);
    }
    final hands = benchHandSnapshots(current.tracking);
    final motion = _head.motion;
    final left = hands[0];
    final right = hands[1];

    return Card(
      key: const Key('bench-tracking-hud'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: SizedBox(
          height: 64,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _HandPreview(
                  snapshot: left,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HandPreview(
                  snapshot: right,
                  color: theme.colorScheme.tertiary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _HeadPosePreview(motion: motion, head: current.head),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HandPreview extends StatelessWidget {
  const _HandPreview({required this.snapshot, required this.color});

  final BenchHandSnapshot snapshot;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hand = snapshot.hand.name;
    return Column(
      children: [
        Row(
          children: [
            Text(
              snapshot.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Text(
              '${snapshot.joints.length} joints',
              key: Key('bench-hand-joints-$hand'),
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
        Expanded(
          child: snapshot.hasJoints
              ? CustomPaint(
                  key: Key('bench-hand-preview-$hand'),
                  painter: HandSkeletonPainter(
                    joints: snapshot.joints,
                    color: color,
                  ),
                  child: const SizedBox.expand(),
                )
              : Center(
                  child: Text(
                    'no joints',
                    key: Key('bench-hand-empty-$hand'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
        ),
      ],
    );
  }
}

class _HeadPosePreview extends StatelessWidget {
  const _HeadPosePreview({required this.motion, required this.head});

  final BenchHeadMotion motion;
  final Pose? head;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          motion.status,
          key: const Key('bench-head-pose-hud'),
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: motion.moving ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          motion.deltaLabel,
          key: const Key('bench-head-pose-delta'),
          style: theme.textTheme.labelSmall,
        ),
        if (head == null) ...[
          const SizedBox(height: 2),
          Text('no head pose yet', style: theme.textTheme.labelSmall),
        ],
      ],
    );
  }
}

/// Draws one hand's joints in the tracking plane.
///
/// Joint translations are metres in tracking space; the painter fits the
/// visible joints into the canvas and flips Y so up is up on screen.
class HandSkeletonPainter extends CustomPainter {
  HandSkeletonPainter({required this.joints, required this.color});

  final Map<HandJoint, TrackedPose> joints;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (joints.isEmpty) return;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final joint in joints.values) {
      final t = joint.pose.translation;
      if (t.x < minX) minX = t.x;
      if (t.x > maxX) maxX = t.x;
      if (t.y < minY) minY = t.y;
      if (t.y > maxY) maxY = t.y;
    }
    final spanX = maxX - minX;
    final spanY = maxY - minY;
    const padding = 6.0;
    final scales = [
      if (spanX > 1e-6) (size.width - 2 * padding) / spanX,
      if (spanY > 1e-6) (size.height - 2 * padding) / spanY,
    ];
    final scale = scales.isEmpty ? 1.0 : scales.reduce(math.min);
    final offsetX = (size.width - spanX * scale) / 2;
    final offsetY = (size.height - spanY * scale) / 2;

    Offset project(TrackedPose pose) {
      final t = pose.pose.translation;
      return Offset(
        offsetX + (t.x - minX) * scale,
        size.height - offsetY - (t.y - minY) * scale,
      );
    }

    final points = {
      for (final entry in joints.entries) entry.key: project(entry.value),
    };
    final bones = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final dots = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final hasPalm = points.containsKey(HandJoint.palm);
    for (final (a, b) in handBones) {
      if (!hasPalm && a == HandJoint.palm) continue;
      final pa = points[a];
      final pb = points[b];
      if (pa != null && pb != null) canvas.drawLine(pa, pb, bones);
    }
    if (!hasPalm) {
      for (final (a, b) in handWristBones) {
        final pa = points[a];
        final pb = points[b];
        if (pa != null && pb != null) canvas.drawLine(pa, pb, bones);
      }
    }
    for (final entry in points.entries) {
      final tip = entry.key.name.endsWith('Tip');
      canvas.drawCircle(entry.value, tip ? 3.2 : 2.0, dots);
    }
  }

  @override
  bool shouldRepaint(HandSkeletonPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.joints != joints;
}

/// OpenXR joint chains, from wrist/palm out to each fingertip.
const List<(HandJoint, HandJoint)> handBones = [
  (HandJoint.wrist, HandJoint.palm),
  (HandJoint.palm, HandJoint.thumbMetacarpal),
  (HandJoint.thumbMetacarpal, HandJoint.thumbProximal),
  (HandJoint.thumbProximal, HandJoint.thumbDistal),
  (HandJoint.thumbDistal, HandJoint.thumbTip),
  (HandJoint.palm, HandJoint.indexMetacarpal),
  (HandJoint.indexMetacarpal, HandJoint.indexProximal),
  (HandJoint.indexProximal, HandJoint.indexIntermediate),
  (HandJoint.indexIntermediate, HandJoint.indexDistal),
  (HandJoint.indexDistal, HandJoint.indexTip),
  (HandJoint.palm, HandJoint.middleMetacarpal),
  (HandJoint.middleMetacarpal, HandJoint.middleProximal),
  (HandJoint.middleProximal, HandJoint.middleIntermediate),
  (HandJoint.middleIntermediate, HandJoint.middleDistal),
  (HandJoint.middleDistal, HandJoint.middleTip),
  (HandJoint.palm, HandJoint.ringMetacarpal),
  (HandJoint.ringMetacarpal, HandJoint.ringProximal),
  (HandJoint.ringProximal, HandJoint.ringIntermediate),
  (HandJoint.ringIntermediate, HandJoint.ringDistal),
  (HandJoint.ringDistal, HandJoint.ringTip),
  (HandJoint.palm, HandJoint.littleMetacarpal),
  (HandJoint.littleMetacarpal, HandJoint.littleProximal),
  (HandJoint.littleProximal, HandJoint.littleIntermediate),
  (HandJoint.littleIntermediate, HandJoint.littleDistal),
  (HandJoint.littleDistal, HandJoint.littleTip),
];

/// Wrist-to-metacarpal fallback for runtimes that omit the palm joint.
const List<(HandJoint, HandJoint)> handWristBones = [
  (HandJoint.wrist, HandJoint.thumbMetacarpal),
  (HandJoint.wrist, HandJoint.indexMetacarpal),
  (HandJoint.wrist, HandJoint.middleMetacarpal),
  (HandJoint.wrist, HandJoint.ringMetacarpal),
  (HandJoint.wrist, HandJoint.littleMetacarpal),
];
