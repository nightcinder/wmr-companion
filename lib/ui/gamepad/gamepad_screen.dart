import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/gamepad.dart';
import '../debug/debug_providers.dart';
import '../debug/stream_settings.dart';
import 'gamepad_providers.dart';

/// Debug view of the gamepad mapping: what a game would see, plus the
/// thresholds. Stays inside the app; nothing is sent to the OS.
class GamepadScreen extends ConsumerWidget {
  const GamepadScreen({super.key, this.source = DebugSource.fake});

  final DebugSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(streamModeProvider).carriesRecords;
    final state = ref.watch(gamepadStateProvider(source));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gamepad mapping')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            records
                ? 'Both controllers mapped onto one two-stick gamepad, inside '
                      'the app only. Thresholds are guesses; not checked on '
                      'hardware.'
                : 'Needs the decoded stream: switch to FF12 or FF14 on the '
                      'debug screen.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          GamepadView(state),
          const SizedBox(height: 16),
          const GamepadSettingsPanel(),
        ],
      ),
    );
  }
}

/// Sticks, triggers and buttons of one [GamepadState].
class GamepadView extends StatelessWidget {
  const GamepadView(this.state, {super.key});

  final GamepadState state;

  static const _labels = {
    GamepadButton.dpadUp: 'Up',
    GamepadButton.dpadDown: 'Down',
    GamepadButton.dpadLeft: 'Left',
    GamepadButton.dpadRight: 'Right',
    GamepadButton.l1: 'L1',
    GamepadButton.l2: 'L2',
    GamepadButton.l3: 'L3',
    GamepadButton.select: 'Select',
    GamepadButton.guide: 'Guide',
    GamepadButton.start: 'Start',
    GamepadButton.r1: 'R1',
    GamepadButton.r2: 'R2',
    GamepadButton.r3: 'R3',
    GamepadButton.y: 'Y',
    GamepadButton.x: 'X',
    GamepadButton.b: 'B',
    GamepadButton.a: 'A',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _Side(
                name: 'LEFT',
                connected: state.leftConnected,
                stick: state.leftStick,
                trigger: state.leftTrigger,
                mono: mono,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _Side(
                name: 'RIGHT',
                connected: state.rightConnected,
                stick: state.rightStick,
                trigger: state.rightTrigger,
                mono: mono,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in _labels.entries)
              ButtonLamp(e.value, on: state.pressed(e.key)),
          ],
        ),
      ],
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    required this.name,
    required this.connected,
    required this.stick,
    required this.trigger,
    this.mono,
  });

  final String name;
  final bool connected;
  final List<double> stick;
  final double trigger;
  final TextStyle? mono;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$name${connected ? '' : ' (no data)'}'),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1,
          child: CustomPaint(
            painter: _StickPainter(
              stick,
              ring: scheme.outline,
              dot: scheme.primary,
            ),
          ),
        ),
        Text('x ${_f(stick[0])}  y ${_f(stick[1])}', style: mono),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: trigger),
        Text('trigger ${trigger.toStringAsFixed(2)}', style: mono),
      ],
    );
  }

  static String _f(double v) =>
      (v >= 0 ? '+' : '') + v.toStringAsFixed(2).padLeft(4);
}

class _StickPainter extends CustomPainter {
  _StickPainter(this.stick, {required this.ring, required this.dot});

  final List<double> stick;
  final Color ring;
  final Color dot;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 4;
    final line = Paint()
      ..color = ring
      ..style = PaintingStyle.stroke;
    canvas
      ..drawCircle(c, r, line)
      ..drawLine(c - Offset(r, 0), c + Offset(r, 0), line)
      ..drawLine(c - Offset(0, r), c + Offset(0, r), line)
      // y is positive up in the model, down on screen.
      ..drawCircle(
        c + Offset(stick[0] * r, -stick[1] * r),
        8,
        Paint()..color = dot,
      );
  }

  @override
  bool shouldRepaint(_StickPainter old) =>
      old.stick[0] != stick[0] ||
      old.stick[1] != stick[1] ||
      old.ring != ring ||
      old.dot != dot;
}

/// One gamepad button, lit while pressed.
class ButtonLamp extends StatelessWidget {
  const ButtonLamp(this.label, {required this.on, super.key});

  final String label;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$label ${on ? 'pressed' : 'released'}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Every threshold and choice of [GamepadConfig], live.
class GamepadSettingsPanel extends ConsumerWidget {
  const GamepadSettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(gamepadConfigProvider);
    final n = ref.read(gamepadConfigProvider.notifier);
    final tilt = c.tilt;
    final small = Theme.of(context).textTheme.bodySmall;
    return ExpansionTile(
      title: const Text('Mapping settings'),
      initiallyExpanded: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stick dead zone and rest centre are on the debug screen.',
          style: small,
        ),
        const SizedBox(height: 8),
        Text('Trigger full scale (raw) ${c.triggerFullScale}'),
        Slider(
          value: c.triggerFullScale.toDouble(),
          min: 64,
          max: 255,
          divisions: 191,
          onChanged: (v) => n.set(c.copyWith(triggerFullScale: v.round())),
        ),
        Text('Trigger dead zone ${c.triggerDeadZone.toStringAsFixed(2)}'),
        Slider(
          value: c.triggerDeadZone,
          max: 0.3,
          divisions: 30,
          onChanged: (v) => n.set(c.copyWith(triggerDeadZone: v)),
        ),
        Text(
          'Trigger press (L2/R2) at '
          '${c.triggerPressThreshold.toStringAsFixed(2)}',
        ),
        Slider(
          value: c.triggerPressThreshold,
          min: 0.05,
          max: 1,
          divisions: 19,
          onChanged: (v) => n.set(c.copyWith(triggerPressThreshold: v)),
        ),
        Text(
          'Trackpad centre (no press) '
          '${c.trackpadCentreRadius.toStringAsFixed(2)}',
        ),
        Slider(
          value: c.trackpadCentreRadius,
          max: 0.8,
          divisions: 16,
          onChanged: (v) => n.set(c.copyWith(trackpadCentreRadius: v)),
        ),
        for (final h in [0, 1]) ...[
          Text('${h == 0 ? 'LEFT' : 'RIGHT'} trackpad click'),
          const SizedBox(height: 4),
          SegmentedButton<TrackpadRole>(
            segments: const [
              ButtonSegment(value: TrackpadRole.none, label: Text('Off')),
              ButtonSegment(value: TrackpadRole.dpad, label: Text('D-pad')),
              ButtonSegment(
                value: TrackpadRole.faceButtons,
                label: Text('ABXY'),
              ),
            ],
            selected: {c.trackpadRole(h)},
            onSelectionChanged: (s) => n.set(
              h == 0
                  ? c.copyWith(leftTrackpad: s.first)
                  : c.copyWith(rightTrackpad: s.first),
            ),
          ),
          const SizedBox(height: 8),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Invert stick Y'),
          value: c.invertStickY,
          onChanged: (v) => n.set(c.copyWith(invertStickY: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Invert trackpad Y'),
          value: c.invertTrackpadY,
          onChanged: (v) => n.set(c.copyWith(invertTrackpadY: v)),
        ),
        const Divider(),
        const Text('Tilt as stick (3DoF)'),
        Text(
          'Roll to x, pitch to y; yaw is not used (it drifts). Where tilt '
          'and the stick both move an axis, the larger wins.',
          style: small,
        ),
        const SizedBox(height: 4),
        SegmentedButton<TiltTarget>(
          segments: const [
            ButtonSegment(value: TiltTarget.none, label: Text('Off')),
            ButtonSegment(
              value: TiltTarget.leftStick,
              label: Text('Left stick'),
            ),
            ButtonSegment(
              value: TiltTarget.rightStick,
              label: Text('Right stick'),
            ),
          ],
          selected: {tilt.target},
          onSelectionChanged: (s) => n.setTilt(tilt.copyWith(target: s.first)),
        ),
        if (tilt.target != TiltTarget.none) ...[
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('LEFT controller')),
              ButtonSegment(value: 1, label: Text('RIGHT controller')),
            ],
            selected: {tilt.hand},
            onSelectionChanged: (s) => n.setTilt(tilt.copyWith(hand: s.first)),
          ),
          Text('Full deflection at ${tilt.maxDegrees.round()}°'),
          Slider(
            value: tilt.maxDegrees,
            min: 10,
            max: 90,
            divisions: 16,
            onChanged: (v) => n.setTilt(tilt.copyWith(maxDegrees: v)),
          ),
          Text('Tilt dead zone ${tilt.deadZoneDegrees.round()}°'),
          Slider(
            value: tilt.deadZoneDegrees,
            max: 15,
            divisions: 15,
            onChanged: (v) => n.setTilt(tilt.copyWith(deadZoneDegrees: v)),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('Invert tilt X'),
                selected: tilt.invertX,
                onSelected: (v) => n.setTilt(tilt.copyWith(invertX: v)),
              ),
              FilterChip(
                label: const Text('Invert tilt Y'),
                selected: tilt.invertY,
                onSelected: (v) => n.setTilt(tilt.copyWith(invertY: v)),
              ),
            ],
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: n.reset,
            child: const Text('Reset mapping settings'),
          ),
        ),
      ],
    );
  }
}
