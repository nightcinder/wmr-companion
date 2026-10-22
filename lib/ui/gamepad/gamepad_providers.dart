import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/gamepad.dart';
import '../../services/gamepad_settings_store.dart';
import '../debug/debug_providers.dart';

/// Where the settings are saved: the app documents directory, or nowhere
/// when that is unavailable (tests, unsupported platform).
final gamepadSettingsStoreProvider = Provider<GamepadSettingsStore>(
  (ref) => _LazyDocumentsStore(),
);

class _LazyDocumentsStore implements GamepadSettingsStore {
  Future<GamepadSettingsStore> _store() async {
    try {
      return FileGamepadSettingsStore(await getApplicationDocumentsDirectory());
    } catch (_) {
      return const NoGamepadSettingsStore();
    }
  }

  late final Future<GamepadSettingsStore> _resolved = _store();

  @override
  Future<GamepadConfig?> load() async => (await _resolved).load();

  @override
  Future<void> save(GamepadConfig config) async =>
      (await _resolved).save(config);
}

/// Pause after the last change before the settings are written.
final gamepadSaveDelayProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 400),
);

/// Gamepad thresholds and choices, live-editable from the gamepad screen and
/// saved across app runs.
final gamepadConfigProvider =
    NotifierProvider<GamepadConfigNotifier, GamepadConfig>(
      GamepadConfigNotifier.new,
    );

/// Starts with the defaults, replaces them with the saved settings once they
/// load (unless the user changed something in the meantime), and saves every
/// change after a short pause so a slider drag writes once.
class GamepadConfigNotifier extends Notifier<GamepadConfig> {
  late final GamepadSettingsStore _store;
  late final Duration _saveDelay;
  Timer? _saveTimer;
  GamepadConfig? _pending;
  bool _touched = false;

  @override
  GamepadConfig build() {
    // Read once here: a provider cannot be read while it is being disposed.
    _store = ref.read(gamepadSettingsStoreProvider);
    _saveDelay = ref.read(gamepadSaveDelayProvider);
    ref.onDispose(() {
      // Do not lose the last change when the container goes away.
      final pending = _pending;
      _saveTimer?.cancel();
      if (pending != null) _save(pending);
    });
    _load();
    return const GamepadConfig();
  }

  Future<void> _load() async {
    GamepadConfig? saved;
    try {
      saved = await _store.load();
    } catch (_) {
      return;
    }
    if (saved != null && !_touched && ref.mounted) state = saved;
  }

  void set(GamepadConfig config) {
    _touched = true;
    state = config;
    _pending = config;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () {
      _pending = null;
      _save(config);
    });
  }

  void setTilt(TiltConfig tilt) => set(state.copyWith(tilt: tilt));

  void reset() => set(const GamepadConfig());

  void _save(GamepadConfig config) {
    // A failed save loses a setting at worst; nothing to tell the user yet.
    _store.save(config).catchError((Object _) {});
  }
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
