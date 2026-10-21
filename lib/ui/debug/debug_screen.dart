import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../../domain/orientation.dart';
import '../../services/controller_service.dart';
import 'debug_providers.dart';
import 'orientation_painter.dart';

class DebugScreen extends ConsumerWidget {
  const DebugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raw =
        ref.watch(orientationProvider).value ?? vm.Quaternion.identity();
    final yawOffset = ref.watch(yawOffsetProvider);
    final q = removeYaw(raw, yawOffset);
    final euler = eulerFromQuaternion(q);
    final stats = ref.watch(streamStatsProvider);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Debug: 3DoF')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Synthetic orientation: IMU decoding and fusion are not '
            'implemented yet. Frames below come from the fake bridge.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: CustomPaint(
              painter: OrientationPainter(
                q,
                edgeColor: theme.colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            'q  w ${_f(q.w)}  x ${_f(q.x)}  y ${_f(q.y)}  z ${_f(q.z)}',
            style: mono,
          ),
          Text(
            'yaw ${_deg(euler.yawDeg)}  pitch ${_deg(euler.pitchDeg)}  '
            'roll ${_deg(euler.rollDeg)}',
            style: mono,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: () => ref.read(yawOffsetProvider.notifier).zeroAt(raw),
              child: const Text('Reset orientation'),
            ),
          ),
          const SizedBox(height: 16),
          Text('Stream', style: theme.textTheme.titleMedium),
          switch (stats) {
            AsyncData(:final value) => _StatsTable(value, style: mono),
            AsyncError(:final error) => Text('Error: $error'),
            _ => const Text('Connecting...'),
          },
        ],
      ),
    );
  }

  static String _f(double v) => v.toStringAsFixed(3).padLeft(6);
  static String _deg(double v) => '${v.toStringAsFixed(1).padLeft(6)}°';
}

class _StatsTable extends StatelessWidget {
  const _StatsTable(this.stats, {this.style});

  final StreamStats stats;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    const hands = ['LEFT', 'RIGHT'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var h = 0; h < stats.hands.length; h++)
          Text(
            '${hands[h].padRight(5)}  frames ${stats.hands[h].frames}  '
            'seq ${stats.hands[h].lastSequence ?? '-'}  '
            'gaps ${stats.hands[h].gaps}  '
            'incomplete ${stats.hands[h].incomplete}',
            style: style,
          ),
        Text('fragment errors ${stats.errors}', style: style),
      ],
    );
  }
}
