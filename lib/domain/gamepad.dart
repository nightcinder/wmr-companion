import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;

import '../protocol/decoded_record.dart';
import 'hand_pipeline.dart';
import 'orientation.dart';
import 'stick_centre.dart';

/// Buttons of the gamepad model: the usual two-stick layout (Android
/// `KEYCODE_BUTTON_*` and XInput name the same set differently).
enum GamepadButton {
  a,
  b,
  x,
  y,
  l1,
  r1,
  l2,
  r2,
  l3,
  r3,
  select,
  start,
  guide,
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
}

/// What one hand's trackpad does when clicked.
enum TrackpadRole {
  none,

  /// 8-way d-pad (diagonals press two directions).
  dpad,

  /// 4-way A/B/X/Y: up Y, right B, down A, left X.
  faceButtons,
}

/// Which stick the tilt of [TiltConfig.hand] drives, if any.
enum TiltTarget { none, leftStick, rightStick }

/// 3DoF tilt as a stick: roll (lean the top of the ring left/right) to x,
/// pitch (tip it away/toward the user) to y. Yaw is not used: it drifts
/// without a magnetometer. Signs follow the view frame and are not checked
/// on hardware; [invertX] and [invertY] fix a backwards axis.
class TiltConfig {
  const TiltConfig({
    this.target = TiltTarget.none,
    this.hand = 1,
    this.maxDegrees = 35,
    this.deadZoneDegrees = 3,
    this.invertX = false,
    this.invertY = false,
  });

  final TiltTarget target;

  /// 0 LEFT, 1 RIGHT.
  final int hand;

  /// Tilt that gives full deflection.
  final double maxDegrees;
  final double deadZoneDegrees;
  final bool invertX;
  final bool invertY;

  TiltConfig copyWith({
    TiltTarget? target,
    int? hand,
    double? maxDegrees,
    double? deadZoneDegrees,
    bool? invertX,
    bool? invertY,
  }) => TiltConfig(
    target: target ?? this.target,
    hand: hand ?? this.hand,
    maxDegrees: maxDegrees ?? this.maxDegrees,
    deadZoneDegrees: deadZoneDegrees ?? this.deadZoneDegrees,
    invertX: invertX ?? this.invertX,
    invertY: invertY ?? this.invertY,
  );

  @override
  bool operator ==(Object other) =>
      other is TiltConfig &&
      other.target == target &&
      other.hand == hand &&
      other.maxDegrees == maxDegrees &&
      other.deadZoneDegrees == deadZoneDegrees &&
      other.invertX == invertX &&
      other.invertY == invertY;

  @override
  int get hashCode =>
      Object.hash(target, hand, maxDegrees, deadZoneDegrees, invertX, invertY);
}

/// Thresholds and choices for [mapGamepad]. Every number here is a guess:
/// the trigger and trackpad ranges are not measured (WMR_Bridge
/// `docs/DECODING.md`, "Unknown"), so all of them are live-editable.
///
/// The stick dead zone and rest centre are not here: they are applied
/// earlier, by `StickNormalizer` (see `StickConfig`).
class GamepadConfig {
  const GamepadConfig({
    this.triggerFullScale = 255,
    this.triggerDeadZone = 0.05,
    this.triggerPressThreshold = 0.5,
    this.trackpadCentreRadius = 0.3,
    this.leftTrackpad = TrackpadRole.dpad,
    this.rightTrackpad = TrackpadRole.faceButtons,
    this.invertStickY = false,
    this.invertTrackpadY = false,
    this.tilt = const TiltConfig(),
  });

  /// Raw trigger value (0..255 on the wire) that counts as fully pulled.
  final int triggerFullScale;

  /// Fraction of [triggerFullScale] below which the analog trigger reads 0.
  final double triggerDeadZone;

  /// Analog trigger value (after the dead zone) at which L2/R2 press.
  final double triggerPressThreshold;

  /// A trackpad click closer to the centre than this (fraction of the
  /// radius) presses nothing.
  final double trackpadCentreRadius;
  final TrackpadRole leftTrackpad;
  final TrackpadRole rightTrackpad;

  /// The model has y positive = up. Whether the wire stick and trackpad y
  /// grow upwards is not checked on hardware.
  final bool invertStickY;
  final bool invertTrackpadY;
  final TiltConfig tilt;

  TrackpadRole trackpadRole(int hand) =>
      hand == 0 ? leftTrackpad : rightTrackpad;

  GamepadConfig copyWith({
    int? triggerFullScale,
    double? triggerDeadZone,
    double? triggerPressThreshold,
    double? trackpadCentreRadius,
    TrackpadRole? leftTrackpad,
    TrackpadRole? rightTrackpad,
    bool? invertStickY,
    bool? invertTrackpadY,
    TiltConfig? tilt,
  }) => GamepadConfig(
    triggerFullScale: triggerFullScale ?? this.triggerFullScale,
    triggerDeadZone: triggerDeadZone ?? this.triggerDeadZone,
    triggerPressThreshold: triggerPressThreshold ?? this.triggerPressThreshold,
    trackpadCentreRadius: trackpadCentreRadius ?? this.trackpadCentreRadius,
    leftTrackpad: leftTrackpad ?? this.leftTrackpad,
    rightTrackpad: rightTrackpad ?? this.rightTrackpad,
    invertStickY: invertStickY ?? this.invertStickY,
    invertTrackpadY: invertTrackpadY ?? this.invertTrackpadY,
    tilt: tilt ?? this.tilt,
  );

  @override
  bool operator ==(Object other) =>
      other is GamepadConfig &&
      other.triggerFullScale == triggerFullScale &&
      other.triggerDeadZone == triggerDeadZone &&
      other.triggerPressThreshold == triggerPressThreshold &&
      other.trackpadCentreRadius == trackpadCentreRadius &&
      other.leftTrackpad == leftTrackpad &&
      other.rightTrackpad == rightTrackpad &&
      other.invertStickY == invertStickY &&
      other.invertTrackpadY == invertTrackpadY &&
      other.tilt == tilt;

  @override
  int get hashCode => Object.hash(
    triggerFullScale,
    triggerDeadZone,
    triggerPressThreshold,
    trackpadCentreRadius,
    leftTrackpad,
    rightTrackpad,
    invertStickY,
    invertTrackpadY,
    tilt,
  );
}

/// The latest state of one controller, as the mapper needs it.
class HandInput {
  const HandInput({
    this.buttons = 0,
    this.stick = const [0, 0],
    this.trigger = 0,
    this.trackpad = const [0, 0],
    this.orientation,
  });

  /// From the pipeline's output: the stick already has its centre and dead
  /// zone removed; the trackpad is scaled to -1..1.
  factory HandInput.fromSample(DecodedSample s) => HandInput(
    buttons: s.record.buttons,
    stick: s.stick,
    trigger: s.record.trigger,
    trackpad: [
      for (final v in s.record.trackpad)
        (v / StickNormalizer.fullScale).clamp(-1.0, 1.0),
    ],
    orientation: s.orientation,
  );

  /// `wmrBtn*` bits.
  final int buttons;

  /// -1..1, after centre and dead zone.
  final List<double> stick;

  /// Raw 0..255.
  final int trigger;

  /// -1..1; both 0 when not touched.
  final List<double> trackpad;

  /// View-frame orientation (X right, Y up, Z toward the user), if fused.
  final vm.Quaternion? orientation;

  bool pressed(int bit) => buttons & bit != 0;
}

/// One frame of the gamepad model. Sticks and triggers are analog; y is
/// positive up.
class GamepadState {
  const GamepadState({
    this.buttons = const {},
    this.leftStick = const [0, 0],
    this.rightStick = const [0, 0],
    this.leftTrigger = 0,
    this.rightTrigger = 0,
    this.leftConnected = false,
    this.rightConnected = false,
  });

  final Set<GamepadButton> buttons;
  final List<double> leftStick;
  final List<double> rightStick;
  final double leftTrigger;
  final double rightTrigger;

  /// Whether a sample of that hand has arrived (the hand's inputs read as
  /// released otherwise).
  final bool leftConnected;
  final bool rightConnected;

  bool pressed(GamepadButton b) => buttons.contains(b);
}

/// Maps both hands onto one gamepad. Pure and stateless: the same inputs and
/// config give the same state, so it can run anywhere (UI isolate now, a
/// native or background hot path later).
///
/// Per hand: stick to that side's stick, squeeze to L1/R1, trigger to the
/// analog L/R trigger (and L2/R2 past [GamepadConfig.triggerPressThreshold]),
/// stick click to L3/R3, menu to Select (LEFT) / Start (RIGHT), home on
/// either hand to Guide, trackpad click to the d-pad or the face buttons
/// ([GamepadConfig.leftTrackpad], [GamepadConfig.rightTrackpad]). BT pairing
/// is not mapped. Optional tilt drives one stick ([TiltConfig]); where both
/// tilt and the physical stick move an axis, the larger magnitude wins.
GamepadState mapGamepad(
  HandInput? left,
  HandInput? right,
  GamepadConfig config,
) {
  final buttons = <GamepadButton>{};
  final hands = [left, right];
  final sticks = <List<double>>[];
  final triggers = <double>[];

  for (var h = 0; h < 2; h++) {
    final input = hands[h];
    if (input == null) {
      sticks.add(const [0, 0]);
      triggers.add(0);
      continue;
    }
    final isLeft = h == 0;
    if (input.pressed(wmrBtnSqueeze)) {
      buttons.add(isLeft ? GamepadButton.l1 : GamepadButton.r1);
    }
    if (input.pressed(wmrBtnThumbstickClick)) {
      buttons.add(isLeft ? GamepadButton.l3 : GamepadButton.r3);
    }
    if (input.pressed(wmrBtnMenu)) {
      buttons.add(isLeft ? GamepadButton.select : GamepadButton.start);
    }
    if (input.pressed(wmrBtnHome)) buttons.add(GamepadButton.guide);

    final t = triggerValue(input.trigger, config);
    triggers.add(t);
    if (t > 0 && t >= config.triggerPressThreshold) {
      buttons.add(isLeft ? GamepadButton.l2 : GamepadButton.r2);
    }

    final sy = config.invertStickY ? -input.stick[1] : input.stick[1];
    sticks.add([_finite(input.stick[0]), _finite(sy)]);

    if (input.pressed(wmrBtnTrackpadClick) &&
        input.pressed(wmrBtnTrackpadTouch)) {
      final ty = config.invertTrackpadY
          ? -input.trackpad[1]
          : input.trackpad[1];
      buttons.addAll(
        trackpadButtons(
          input.trackpad[0],
          ty,
          config.trackpadRole(h),
          config.trackpadCentreRadius,
        ),
      );
    }
  }

  final tilt = config.tilt;
  if (tilt.target != TiltTarget.none) {
    final q = hands[tilt.hand.clamp(0, 1)]?.orientation;
    if (q != null) {
      final v = tiltStick(q, tilt);
      final i = tilt.target == TiltTarget.leftStick ? 0 : 1;
      sticks[i] = [_larger(sticks[i][0], v[0]), _larger(sticks[i][1], v[1])];
    }
  }

  return GamepadState(
    buttons: buttons,
    leftStick: sticks[0],
    rightStick: sticks[1],
    leftTrigger: triggers[0],
    rightTrigger: triggers[1],
    leftConnected: left != null,
    rightConnected: right != null,
  );
}

/// Raw trigger to 0..1: scale by [GamepadConfig.triggerFullScale], remove
/// the dead zone and rescale so full scale is still 1.
double triggerValue(int raw, GamepadConfig config) {
  final full = math.max(1, config.triggerFullScale);
  final v = (raw / full).clamp(0.0, 1.0);
  final dz = config.triggerDeadZone.clamp(0.0, 0.95);
  if (v <= dz) return 0;
  return ((v - dz) / (1 - dz)).clamp(0.0, 1.0);
}

/// sin(22.5 deg): a component above this share of the radius presses its
/// direction, which gives 8 equal sectors.
const double _diagonal = 0.38268343236508984;

/// Buttons for a trackpad click at ([x], [y]) (-1..1, y up).
Set<GamepadButton> trackpadButtons(
  double x,
  double y,
  TrackpadRole role,
  double centreRadius,
) {
  if (!x.isFinite || !y.isFinite) return const {};
  final r = math.sqrt(x * x + y * y);
  if (r < centreRadius || r == 0) return const {};
  switch (role) {
    case TrackpadRole.none:
      return const {};
    case TrackpadRole.dpad:
      return {
        if (y / r > _diagonal) GamepadButton.dpadUp,
        if (y / r < -_diagonal) GamepadButton.dpadDown,
        if (x / r > _diagonal) GamepadButton.dpadRight,
        if (x / r < -_diagonal) GamepadButton.dpadLeft,
      };
    case TrackpadRole.faceButtons:
      if (x.abs() > y.abs()) {
        return {x > 0 ? GamepadButton.b : GamepadButton.x};
      }
      return {y > 0 ? GamepadButton.y : GamepadButton.a};
  }
}

/// Tilt of [q] as a stick value: x from roll (top of the ring leaning right
/// gives +x), y from pitch (top tipping away from the user gives +y). Both
/// go through a dead zone and saturate at [TiltConfig.maxDegrees].
List<double> tiltStick(vm.Quaternion q, TiltConfig config) {
  final e = eulerFromQuaternion(q);
  // Leaning right is a negative rotation about Z (toward the user); tipping
  // away is a negative rotation about X (right).
  var x = _tiltAxis(-e.rollDeg, config);
  var y = _tiltAxis(-e.pitchDeg, config);
  if (config.invertX) x = -x;
  if (config.invertY) y = -y;
  return [x, y];
}

double _tiltAxis(double degrees, TiltConfig config) {
  if (!degrees.isFinite) return 0;
  final dz = math.max(0.0, config.deadZoneDegrees);
  final span = config.maxDegrees - dz;
  if (span <= 0) return 0;
  final a = degrees.abs();
  if (a <= dz) return 0;
  return degrees.sign * math.min(1.0, (a - dz) / span);
}

double _larger(double a, double b) => a.abs() >= b.abs() ? a : b;

double _finite(double v) => v.isFinite ? v.clamp(-1.0, 1.0) : 0;

/// Version of the stored settings format; bump when a field changes meaning.
const int gamepadSettingsVersion = 1;

/// [config] as a JSON-encodable map, for [GamepadSettingsStore]. Enums are
/// stored by name so a reordered enum cannot change a saved setting.
Map<String, Object?> gamepadConfigToJson(GamepadConfig config) => {
  'version': gamepadSettingsVersion,
  'triggerFullScale': config.triggerFullScale,
  'triggerDeadZone': config.triggerDeadZone,
  'triggerPressThreshold': config.triggerPressThreshold,
  'trackpadCentreRadius': config.trackpadCentreRadius,
  'leftTrackpad': config.leftTrackpad.name,
  'rightTrackpad': config.rightTrackpad.name,
  'invertStickY': config.invertStickY,
  'invertTrackpadY': config.invertTrackpadY,
  'tilt': {
    'target': config.tilt.target.name,
    'hand': config.tilt.hand,
    'maxDegrees': config.tilt.maxDegrees,
    'deadZoneDegrees': config.tilt.deadZoneDegrees,
    'invertX': config.tilt.invertX,
    'invertY': config.tilt.invertY,
  },
};

/// Reads [gamepadConfigToJson] output. Tolerant: a missing, mistyped,
/// unknown or out-of-range field falls back to its default (numbers are
/// clamped to what the screen's sliders allow), so an old or hand-edited file
/// never breaks startup. Null if [json] is not a map or has a newer version.
GamepadConfig? gamepadConfigFromJson(Object? json) {
  if (json is! Map) return null;
  final version = json['version'];
  if (version is int && version > gamepadSettingsVersion) return null;
  const d = GamepadConfig();
  const dt = TiltConfig();

  double num_(Object? v, double def, double lo, double hi) =>
      v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : def;
  int int_(Object? v, int def, int lo, int hi) =>
      v is num && v.isFinite ? v.round().clamp(lo, hi) : def;
  bool bool_(Object? v, bool def) => v is bool ? v : def;
  T enum_<T extends Enum>(List<T> values, Object? v, T def) =>
      values.asNameMap()[v] ?? def;

  final t = json['tilt'] is Map ? json['tilt'] as Map : const {};
  return GamepadConfig(
    triggerFullScale: int_(
      json['triggerFullScale'],
      d.triggerFullScale,
      64,
      255,
    ),
    triggerDeadZone: num_(json['triggerDeadZone'], d.triggerDeadZone, 0, 0.3),
    triggerPressThreshold: num_(
      json['triggerPressThreshold'],
      d.triggerPressThreshold,
      0.05,
      1,
    ),
    trackpadCentreRadius: num_(
      json['trackpadCentreRadius'],
      d.trackpadCentreRadius,
      0,
      0.8,
    ),
    leftTrackpad: enum_(
      TrackpadRole.values,
      json['leftTrackpad'],
      d.leftTrackpad,
    ),
    rightTrackpad: enum_(
      TrackpadRole.values,
      json['rightTrackpad'],
      d.rightTrackpad,
    ),
    invertStickY: bool_(json['invertStickY'], d.invertStickY),
    invertTrackpadY: bool_(json['invertTrackpadY'], d.invertTrackpadY),
    tilt: TiltConfig(
      target: enum_(TiltTarget.values, t['target'], dt.target),
      hand: int_(t['hand'], dt.hand, 0, 1),
      maxDegrees: num_(t['maxDegrees'], dt.maxDegrees, 10, 90),
      deadZoneDegrees: num_(t['deadZoneDegrees'], dt.deadZoneDegrees, 0, 15),
      invertX: bool_(t['invertX'], dt.invertX),
      invertY: bool_(t['invertY'], dt.invertY),
    ),
  );
}
