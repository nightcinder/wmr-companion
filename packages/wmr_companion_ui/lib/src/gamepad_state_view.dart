import 'package:flutter/material.dart';
import 'package:wmr_companion/wmr_companion.dart';

/// A compact read-out of [GamepadState] for a gamepad tester screen.
///
/// The host owns the state layer; this widget only renders one sample.
class GamepadStateView extends StatelessWidget {
  const GamepadStateView(this.state, {super.key, this.style});

  final GamepadState state;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final buttons = state.buttons.map((b) => b.name).toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'connected L ${state.leftConnected}  R ${state.rightConnected}',
          style: style,
        ),
        Text(
          'sticks L ${_pair(state.leftStick)}  R ${_pair(state.rightStick)}',
          style: style,
        ),
        Text(
          'triggers L ${state.leftTrigger.toStringAsFixed(2)}  '
          'R ${state.rightTrigger.toStringAsFixed(2)}',
          style: style,
        ),
        Text(
          'buttons ${buttons.isEmpty ? '-' : buttons.join(', ')}',
          style: style,
        ),
      ],
    );
  }

  static String _pair(List<double> v) =>
      '[${v.map((e) => e.toStringAsFixed(2)).join(', ')}]';
}
