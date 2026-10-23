import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/axis_mapping.dart';
import '../../domain/hand_pipeline.dart';
import '../../domain/imu_calibration.dart';
import '../../domain/stick_centre.dart';
import '../../services/controller_service.dart';
import '../../services/stick_settings_store.dart';

/// Which bridge stream the app wants. Applied to the service when it is
/// created and on change; the Capture screen needs [StreamMode.raw]. The
/// default is FF14: the owner chose it on 2026-10-22 because it needs about
/// six times fewer notifications than FF12 for the same records (bench A/B/A
/// in docs/STATUS.md; its effect on report loss is not established).
final streamModeProvider = NotifierProvider<StreamModeNotifier, StreamMode>(
  StreamModeNotifier.new,
);

class StreamModeNotifier extends Notifier<StreamMode> {
  @override
  StreamMode build() => StreamMode.batched;

  void set(StreamMode mode) => state = mode;
}

/// The hand whose orientation the debug view shows.
final selectedHandProvider = NotifierProvider<SelectedHand, int>(
  SelectedHand.new,
);

class SelectedHand extends Notifier<int> {
  @override
  int build() => 0;

  void set(int hand) => state = hand;
}

/// The sensor-to-view axis table, with the debug panel's flip toggles.
final axisMappingProvider = NotifierProvider<AxisMappingNotifier, AxisMapping>(
  AxisMappingNotifier.new,
);

class AxisMappingNotifier extends Notifier<AxisMapping> {
  @override
  AxisMapping build() => AxisMapping.defaultMapping;

  void setFlip(int viewAxis, bool value) =>
      state = state.withFlip(viewAxis, value);

  void setGyroFlip(int viewAxis, bool value) =>
      state = state.withGyroFlip(viewAxis, value);

  void reset() => state = AxisMapping.defaultMapping;
}

final filterKindProvider = NotifierProvider<FilterKindNotifier, FilterKind>(
  FilterKindNotifier.new,
);

class FilterKindNotifier extends Notifier<FilterKind> {
  @override
  FilterKind build() => FilterKind.madgwick;

  void set(FilterKind kind) => state = kind;
}

/// Where the stick settings are saved: the app documents directory, or
/// nowhere when that is unavailable (tests, unsupported platform).
final stickSettingsStoreProvider = Provider<StickSettingsStore>(
  (ref) => _LazyStickDocumentsStore(),
);

class _LazyStickDocumentsStore implements StickSettingsStore {
  Future<StickSettingsStore> _store() async {
    try {
      return FileStickSettingsStore(await getApplicationDocumentsDirectory());
    } catch (_) {
      return const NoStickSettingsStore();
    }
  }

  late final Future<StickSettingsStore> _resolved = _store();

  @override
  Future<StickSettings?> load() async => (await _resolved).load();

  @override
  Future<void> save(StickSettings settings) async =>
      (await _resolved).save(settings);
}

/// Pause after the last change before the settings are written.
final stickSaveDelayProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 400),
);

/// Stick dead zone, rest-centre learning and the learned centre of each hand,
/// live-editable from the debug screen and saved across app runs.
final stickSettingsProvider =
    NotifierProvider<StickSettingsNotifier, StickSettings>(
      StickSettingsNotifier.new,
    );

/// The options alone, for consumers that do not care about the centres.
final stickConfigProvider = Provider<StickConfig>(
  (ref) => ref.watch(stickSettingsProvider).config,
);

/// Starts with the defaults, replaces them with the saved settings once they
/// load (unless the user changed something in the meantime), and saves every
/// change after a short pause so a slider drag writes once.
class StickSettingsNotifier extends Notifier<StickSettings> {
  late final StickSettingsStore _store;
  late final Duration _saveDelay;
  Timer? _saveTimer;
  StickSettings? _pending;
  bool _touched = false;

  @override
  StickSettings build() {
    // Read once here: a provider cannot be read while it is being disposed.
    _store = ref.read(stickSettingsStoreProvider);
    _saveDelay = ref.read(stickSaveDelayProvider);
    ref.onDispose(() {
      // Do not lose the last change when the container goes away.
      final pending = _pending;
      _saveTimer?.cancel();
      if (pending != null) _save(pending);
    });
    _load();
    return const StickSettings();
  }

  Future<void> _load() async {
    StickSettings? saved;
    try {
      saved = await _store.load();
    } catch (_) {
      return;
    }
    if (saved != null && !_touched && ref.mounted) state = saved;
  }

  void setDeadZone(double v) =>
      _set(state.copyWith(config: state.config.copyWith(deadZone: v)));

  void setLearn(bool v) =>
      _set(state.copyWith(config: state.config.copyWith(learn: v)));

  /// Records a newly learned or manual centre for [hand] (0 LEFT, 1 RIGHT).
  void setCentre(int hand, double cx, double cy) {
    if (hand < 0 || hand >= state.centres.length) return;
    if (!cx.isFinite || !cy.isFinite) return;
    final x = cx.clamp(-1.0, 1.0).toDouble();
    final y = cy.clamp(-1.0, 1.0).toDouble();
    final current = state.centres[hand];
    if (current != null && current[0] == x && current[1] == y) return;
    final centres = [...state.centres]..[hand] = [x, y];
    _set(state.copyWith(centres: centres));
  }

  /// Forgets the centre of [hand]; learning starts from zero again.
  void clearCentre(int hand) {
    if (hand < 0 || hand >= state.centres.length) return;
    if (state.centres[hand] == null) return;
    final centres = [...state.centres]..[hand] = null;
    _set(state.copyWith(centres: centres));
  }

  void set(StickSettings settings) => _set(settings);

  void reset() => _set(const StickSettings());

  void _set(StickSettings settings) {
    _touched = true;
    state = settings;
    _pending = settings;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () {
      _pending = null;
      _save(settings);
    });
  }

  void _save(StickSettings settings) {
    // A failed save loses a setting at worst; nothing to tell the user yet.
    _store.save(settings).catchError((Object _) {});
  }
}

/// Applies the saved stick options and rest centres to [service].
void applyStickSettings(ControllerService service, StickSettings settings) {
  service.setStickConfig(settings.config);
  applyStickCentres(service, settings.centres);
}

/// Applies [centres] (index 0 LEFT, 1 RIGHT) to [service]; null clears the
/// hand's saved centre.
void applyStickCentres(ControllerService service, List<List<double>?> centres) {
  for (var h = 0; h < centres.length; h++) {
    final centre = centres[h];
    if (centre == null) {
      service.clearStickCentre(h);
    } else {
      service.setStickCentre(h, centre[0], centre[1]);
    }
  }
}

/// FF13 calibration per hand (index 0 LEFT, 1 RIGHT), and whether the debug
/// switch applies it. Default off: it has not been run on hardware. Not
/// persisted: only the gamepad settings and the stick options/centres are
/// saved.
class Ff13Settings {
  const Ff13Settings({required this.calibrations, required this.apply});

  final List<ImuCalibration?> calibrations;
  final List<bool> apply;
}

final ff13SettingsProvider =
    NotifierProvider<Ff13SettingsNotifier, Ff13Settings>(
      Ff13SettingsNotifier.new,
    );

class Ff13SettingsNotifier extends Notifier<Ff13Settings> {
  @override
  Ff13Settings build() => Ff13Settings(
    calibrations: List<ImuCalibration?>.filled(2, null),
    apply: List<bool>.filled(2, false),
  );

  /// Stores the calibration decoded from a successful read. A failed read or
  /// a missing key clears it and turns the switch off for that hand: a stale
  /// block is not silently kept in use.
  void setCalibration(int hand, ImuCalibration? calibration) {
    final calibrations = [...state.calibrations]..[hand] = calibration;
    final apply = [...state.apply];
    if (calibration == null) apply[hand] = false;
    state = Ff13Settings(calibrations: calibrations, apply: apply);
  }

  /// Ignored until a calibration has been read for [hand].
  void setApply(int hand, bool value) {
    if (state.calibrations[hand] == null) return;
    final apply = [...state.apply]..[hand] = value;
    state = Ff13Settings(calibrations: state.calibrations, apply: apply);
  }
}

/// Pushes the current FF13 settings into [service], both hands.
void applyFf13Settings(ControllerService service, Ff13Settings settings) {
  for (var h = 0; h < settings.calibrations.length; h++) {
    service.setFf13Calibration(
      h,
      settings.calibrations[h],
      apply: settings.apply[h],
    );
  }
}
