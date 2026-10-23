import 'package:wmr_core/domain/axis_mapping.dart';
import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/domain/stick_centre.dart';
import 'package:wmr_core/services/controller_service.dart' show StreamMode;

/// Fusion filter and its gains.
///
/// Kept as one value so a facade can switch filter without losing the other
/// filter's remembered gains (the same rule as `wmr_core`'s `FilterTuning`).
class FusionConfig {
  const FusionConfig({
    this.kind = FilterKind.madgwick,
    this.tuning = const FilterTuning(),
  });

  factory FusionConfig.madgwick({double beta = 0.05}) => FusionConfig(
    kind: FilterKind.madgwick,
    tuning: FilterTuning(beta: beta),
  );

  factory FusionConfig.mahony({double kp = 1.0, double ki = 0.0}) =>
      FusionConfig(
        kind: FilterKind.mahony,
        tuning: FilterTuning(mahonyKp: kp, mahonyKi: ki),
      );

  final FilterKind kind;
  final FilterTuning tuning;
}

/// Everything the facade needs to run a session.
///
/// Platform hints that are not part of [BleTransport] (MTU request, Android
/// connection priority) stay with the BLE package in phase 3; the facade does
/// not pretend to apply them.
class WmrCompanionConfig {
  const WmrCompanionConfig({
    this.streamMode = StreamMode.batched,
    this.fusion = const FusionConfig(),
    this.axisMapping = AxisMapping.defaultMapping,
    this.gamepad = const GamepadConfig(),
    this.sticks = const StickConfig(),
    this.autoReconnect = true,
  });

  /// FF11 raw, FF12 decoded, FF14 batched or none.
  final StreamMode streamMode;
  final FusionConfig fusion;
  final AxisMapping axisMapping;
  final GamepadConfig gamepad;
  final StickConfig sticks;

  /// Retry once after an unexpected disconnect (state [reconnecting]).
  final bool autoReconnect;

  WmrCompanionConfig copyWith({
    StreamMode? streamMode,
    FusionConfig? fusion,
    AxisMapping? axisMapping,
    GamepadConfig? gamepad,
    StickConfig? sticks,
    bool? autoReconnect,
  }) => WmrCompanionConfig(
    streamMode: streamMode ?? this.streamMode,
    fusion: fusion ?? this.fusion,
    axisMapping: axisMapping ?? this.axisMapping,
    gamepad: gamepad ?? this.gamepad,
    sticks: sticks ?? this.sticks,
    autoReconnect: autoReconnect ?? this.autoReconnect,
  );
}
