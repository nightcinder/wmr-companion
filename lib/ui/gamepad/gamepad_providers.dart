import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/gamepad.dart';
import '../debug/debug_providers.dart';

/// Gamepad thresholds and choices, live-editable from the gamepad screen.
final gamepadConfigProvider =
    NotifierProvider<GamepadConfigNotifier, GamepadConfig>(
      GamepadConfigNotifier.new,
    );

class GamepadConfigNotifier extends Notifier<GamepadConfig> {
  @override
  GamepadConfig build() => const GamepadConfig();

  void set(GamepadConfig config) => state = config;

  void setTilt(TiltConfig tilt) => state = state.copyWith(tilt: tilt);

  void reset() => state = const GamepadConfig();
}

/// The latest input of each hand (null until a sample of that hand arrived).
class GamepadInputs {
  const GamepadInputs(this.left, this.right);

  final HandInput? left;
  final HandInput? right;
}

/// Latest input per hand from the service's decoded samples, about 30 times a
/// second. Empty until [controllerServiceProvider] has a service; raw (FF11)
/// mode delivers no samples, so both hands stay null there.
final gamepadInputsProvider = StreamProvider.family<GamepadInputs, DebugSource>(
  (ref, source) {
    final service = ref.watch(controllerServiceProvider(source));
    if (service == null) return const Stream.empty();
    final latest = <HandInput?>[null, null];
    final sub = service.decodedSamples.listen((s) {
      latest[s.record.hand] = HandInput.fromSample(s);
    });
    ref.onDispose(sub.cancel);
    return Stream.periodic(
      const Duration(milliseconds: 33),
      (_) => GamepadInputs(latest[0], latest[1]),
    );
  },
);

/// The mapped gamepad state for [source].
final gamepadStateProvider = Provider.family<GamepadState, DebugSource>((
  ref,
  source,
) {
  final inputs = ref.watch(gamepadInputsProvider(source)).value;
  return mapGamepad(
    inputs?.left,
    inputs?.right,
    ref.watch(gamepadConfigProvider),
  );
});
