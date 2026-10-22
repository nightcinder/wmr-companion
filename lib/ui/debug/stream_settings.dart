import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/axis_mapping.dart';
import '../../domain/hand_pipeline.dart';
import '../../domain/imu_calibration.dart';
import '../../domain/stick_centre.dart';
import '../../services/controller_service.dart';

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

/// Stick dead zone and rest-centre learning, applied to both hands.
final stickConfigProvider = NotifierProvider<StickConfigNotifier, StickConfig>(
  StickConfigNotifier.new,
);

class StickConfigNotifier extends Notifier<StickConfig> {
  @override
  StickConfig build() => const StickConfig();

  void setDeadZone(double v) => state = state.copyWith(deadZone: v);

  void setLearn(bool v) => state = state.copyWith(learn: v);
}

/// FF13 calibration per hand (index 0 LEFT, 1 RIGHT), and whether the debug
/// switch applies it. Default off: it has not been run on hardware. Not
/// persisted, like the other debug-screen settings (only the gamepad settings
/// are saved).
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
