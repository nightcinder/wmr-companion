import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Gives the VITURE Pro Neckband a complete control path without a D-pad,
/// a hand cursor, or ADB.
///
/// The Neckband has a Settings button, a power button and a volume rocker, but
/// no directional pad. Its Android build therefore fits the app to the
/// glasses, not to a remote. This widget maps the volume rocker to focus
/// navigation:
///
/// * a short Volume Down / Volume Up press moves focus forward / back;
/// * holding Volume Down activates the focused control;
/// * holding Volume Up goes back.
///
/// When the Neckband's headgaze mode is on, the system consumes the rocker
/// first (Volume Down confirms, Volume Up goes back) and this handler does
/// not see those presses. Both paths can be offered at once.
///
/// While a text field owns focus the rocker is left alone, so it still
/// adjusts the volume during text entry.
class NeckbandButtonNavigator extends StatefulWidget {
  const NeckbandButtonNavigator({
    super.key,
    required this.child,
    required this.navigatorKey,
    this.longPress = const Duration(milliseconds: 600),
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  final Duration longPress;

  @override
  State<NeckbandButtonNavigator> createState() =>
      _NeckbandButtonNavigatorState();
}

class _NeckbandButtonNavigatorState extends State<NeckbandButtonNavigator> {
  final Map<LogicalKeyboardKey, Timer> _holdTimers = {};
  final Set<LogicalKeyboardKey> _holdFired = {};

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    for (final timer in _holdTimers.values) {
      timer.cancel();
    }
    _holdTimers.clear();
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    final isDown = event.logicalKey == LogicalKeyboardKey.audioVolumeDown;
    final isUp = event.logicalKey == LogicalKeyboardKey.audioVolumeUp;
    if (!isDown && !isUp) return false;
    if (_isEditingText) return false;
    if (event is KeyDownEvent) {
      _holdTimers[event.logicalKey]?.cancel();
      _holdFired.remove(event.logicalKey);
      _holdTimers[event.logicalKey] = Timer(widget.longPress, () {
        if (!mounted) return;
        _holdFired.add(event.logicalKey);
        if (isDown) {
          _activateFocused();
        } else {
          _goBack();
        }
      });
      return true;
    }
    if (event is KeyUpEvent) {
      final timer = _holdTimers.remove(event.logicalKey);
      final fired = _holdFired.remove(event.logicalKey);
      timer?.cancel();
      if (!fired) {
        if (isDown) {
          _moveFocus(forward: true);
        } else {
          _moveFocus(forward: false);
        }
      }
      return true;
    }
    return true;
  }

  /// True while an [EditableText] owns focus, so the rocker keeps its normal
  /// volume role during Wi-Fi and token entry.
  bool get _isEditingText {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _moveFocus({required bool forward}) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) {
      FocusScope.of(context).nextFocus();
      return;
    }
    if (forward) {
      focus.nextFocus();
    } else {
      focus.previousFocus();
    }
  }

  void _activateFocused() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (focus == null || context == null) {
      _moveFocus(forward: true);
      return;
    }
    focus.requestFocus();
    Actions.maybeInvoke(context, const ActivateIntent());
  }

  void _goBack() {
    final navigator = widget.navigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
