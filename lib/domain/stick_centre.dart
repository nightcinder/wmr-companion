import 'dart:math' as math;

/// Settings for [StickNormalizer]. Live-editable from the debug panel.
class StickConfig {
  const StickConfig({this.deadZone = 0.05, this.learn = true});

  /// Radial dead zone as a fraction of full deflection, applied after the
  /// centre is removed. Output is rescaled so full deflection still gives 1.
  final double deadZone;

  /// Learn the rest centre automatically (see [StickNormalizer]).
  final bool learn;

  StickConfig copyWith({double? deadZone, bool? learn}) => StickConfig(
    deadZone: deadZone ?? this.deadZone,
    learn: learn ?? this.learn,
  );

  @override
  bool operator ==(Object other) =>
      other is StickConfig &&
      other.deadZone == deadZone &&
      other.learn == learn;

  @override
  int get hashCode => Object.hash(deadZone, learn);
}

/// Everything the app keeps between runs about the sticks: the live settings
/// and, per hand (0 LEFT, 1 RIGHT), the learned or manual rest centre.
class StickSettings {
  const StickSettings({
    this.config = const StickConfig(),
    this.centres = const [null, null],
  });

  final StickConfig config;

  /// Rest centre per hand as a fraction of full scale, or null before one has
  /// been learned or set.
  final List<List<double>?> centres;

  List<double>? centreFor(int hand) =>
      hand >= 0 && hand < centres.length ? centres[hand] : null;

  StickSettings copyWith({StickConfig? config, List<List<double>?>? centres}) =>
      StickSettings(
        config: config ?? this.config,
        centres: centres ?? this.centres,
      );

  @override
  bool operator ==(Object other) {
    if (other is! StickSettings ||
        other.config != config ||
        other.centres.length != centres.length) {
      return false;
    }
    for (var h = 0; h < centres.length; h++) {
      final a = centres[h];
      final b = other.centres[h];
      if (a == null || b == null) {
        if (a != b) return false;
        continue;
      }
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    config,
    Object.hashAll([
      for (final centre in centres)
        centre == null ? null : Object.hashAll(centre),
    ]),
  );
}

const int stickSettingsVersion = 1;

Map<String, Object?> stickSettingsToJson(StickSettings settings) => {
  'version': stickSettingsVersion,
  'deadZone': settings.config.deadZone,
  'learn': settings.config.learn,
  'centres': [
    for (final centre in settings.centres)
      centre == null ? null : [centre[0], centre[1]],
  ],
};

/// Reads [stickSettingsToJson] output. Tolerant: a missing, mistyped or
/// out-of-range field falls back to its default (the dead zone is clamped to
/// the slider range), and a malformed or non-finite centre is dropped. Null
/// if [json] is not a map or has a newer version.
StickSettings? stickSettingsFromJson(Object? json) {
  if (json is! Map) return null;
  final version = json['version'];
  if (version is int && version > stickSettingsVersion) return null;

  const defaults = StickSettings();
  double num_(Object? v, double def, double lo, double hi) =>
      v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : def;

  final raw = json['centres'];
  final centres = <List<double>?>[];
  for (var h = 0; h < defaults.centres.length; h++) {
    final value = raw is List && h < raw.length ? raw[h] : null;
    if (value is List &&
        value.length >= 2 &&
        value[0] is num &&
        value[1] is num &&
        (value[0] as num).isFinite &&
        (value[1] as num).isFinite) {
      centres.add([
        (value[0] as num).toDouble().clamp(-1.0, 1.0),
        (value[1] as num).toDouble().clamp(-1.0, 1.0),
      ]);
    } else {
      centres.add(null);
    }
  }

  return StickSettings(
    config: StickConfig(
      deadZone: num_(json['deadZone'], defaults.config.deadZone, 0, 0.3),
      learn: json['learn'] is bool
          ? json['learn'] as bool
          : defaults.config.learn,
    ),
    centres: centres,
  );
}

/// Turns the raw thumbstick (i16 per axis, -32767..32767) of one hand into a
/// normalized -1..1 pair with the rest offset removed.
///
/// A stick can rest off-centre (one user-reported measurement: RIGHT y about
/// 0.148 of full scale; not established for other units). The rest centre is
/// learned: when learning is on, the controller is not otherwise being moved
/// (the caller passes `busy`), and the stick stays inside a [window] of zero
/// and within [stillTolerance] of where the candidate started for
/// [holdSeconds], the mean of that stretch becomes the centre. Holding the
/// stick still and slightly deflected inside the window for that long is
/// therefore taken as rest; [recentre] and [reset] are the manual overrides.
///
/// Output: subtract the centre, rescale each half-axis so the physical end
/// stop still reaches +-1, clamp, then apply the radial dead zone (rescaled so
/// the edge of the zone is 0 and full deflection is 1).
///
/// Time comes from the caller (sum of tick `dt`), never the phone clock.
class StickNormalizer {
  StickNormalizer({
    this.window = 0.25,
    this.holdSeconds = 1.0,
    this.stillTolerance = 0.02,
    this.maxStep = 0.1,
    this.onCentreChanged,
  });

  static const double fullScale = 32767;

  /// Called when a new centre is learned or [recentre] sets one, so the app
  /// can save it. Restoring a saved centre does not call it.
  final void Function(List<double> centre)? onCentreChanged;

  /// Largest distance from zero (the nominal centre) at which a rest can be
  /// learned, in fraction of full scale.
  final double window;
  final double holdSeconds;
  final double stillTolerance;

  /// A longer step (a gap) restarts the candidate.
  final double maxStep;

  double _cx = 0;
  double _cy = 0;
  bool _hasCentre = false;
  int _centreUpdates = 0;
  double _lastX = 0;
  double _lastY = 0;
  bool _haveLast = false;

  // Candidate rest stretch.
  bool _inWindow = false;
  double _ax = 0;
  double _ay = 0;
  double _sumX = 0;
  double _sumY = 0;
  int _n = 0;
  double _held = 0;

  /// Learned or manual centre, fraction of full scale.
  List<double> get centre => [_cx, _cy];

  /// Whether a centre was set (learned or by [recentre]) since the last
  /// [reset].
  bool get hasCentre => _hasCentre;

  /// How many times the centre was set.
  int get centreUpdates => _centreUpdates;

  /// Fraction of the hold time collected for the current candidate, 0..1.
  double get learnProgress => _inWindow ? math.min(1, _held / holdSeconds) : 0;

  /// Forgets the centre and the candidate.
  void reset() {
    _cx = 0;
    _cy = 0;
    _hasCentre = false;
    _centreUpdates = 0;
    _haveLast = false;
    breakWindow();
  }

  /// Drops the candidate stretch (gap, reconnect, controller moved), keeps
  /// the centre.
  void breakWindow() {
    _inWindow = false;
    _sumX = 0;
    _sumY = 0;
    _n = 0;
    _held = 0;
  }

  /// Takes the latest raw reading as the centre. Does nothing before the
  /// first sample.
  void recentre() {
    if (!_haveLast) return;
    _setCentre(_lastX, _lastY, notify: true);
  }

  /// Restores a saved centre (fraction of full scale). Invalid readings are
  /// ignored; a restore is not reported through [onCentreChanged].
  void restoreCentre(double cx, double cy) {
    if (!cx.isFinite || !cy.isFinite) return;
    _setCentre(cx, cy);
  }

  void _setCentre(double cx, double cy, {bool notify = false}) {
    final x = cx.clamp(-1.0, 1.0).toDouble();
    final y = cy.clamp(-1.0, 1.0).toDouble();
    final changed = !_hasCentre || _cx != x || _cy != y;
    _cx = x;
    _cy = y;
    _hasCentre = true;
    breakWindow();
    if (!changed) return;
    _centreUpdates++;
    if (notify) onCentreChanged?.call(centre);
  }

  /// Normalizes one sample. [dt] is the controller-time step since the
  /// previous sample of this hand (0 for a baseline); [busy] means the
  /// controller is being moved or pressed in some other way.
  List<double> process(
    int rawX,
    int rawY, {
    required double dt,
    required bool busy,
    required StickConfig config,
  }) {
    final x = (rawX / fullScale).clamp(-1.0, 1.0);
    final y = (rawY / fullScale).clamp(-1.0, 1.0);
    _lastX = x;
    _lastY = y;
    _haveLast = true;
    if (config.learn) {
      _learn(x, y, dt, busy);
    } else {
      breakWindow();
    }
    return _output(x, y, config.deadZone);
  }

  void _learn(double x, double y, double dt, bool busy) {
    final inside = math.sqrt(x * x + y * y) <= window;
    if (busy || !inside) {
      breakWindow();
      return;
    }
    if (dt <= 0 ||
        dt > maxStep ||
        !_inWindow ||
        _drift(x, y) > stillTolerance) {
      breakWindow();
      _start(x, y);
      return;
    }
    _sumX += x;
    _sumY += y;
    _n++;
    _held += dt;
    if (_held >= holdSeconds) {
      _setCentre(_sumX / _n, _sumY / _n, notify: true);
    }
  }

  double _drift(double x, double y) =>
      math.sqrt((x - _ax) * (x - _ax) + (y - _ay) * (y - _ay));

  void _start(double x, double y) {
    _inWindow = true;
    _ax = x;
    _ay = y;
    _sumX = x;
    _sumY = y;
    _n = 1;
    _held = 0;
  }

  List<double> _output(double x, double y, double deadZone) {
    final dx = x - _cx;
    final dy = y - _cy;
    var vx = (dx >= 0 ? dx / _span(1 - _cx) : dx / _span(1 + _cx));
    var vy = (dy >= 0 ? dy / _span(1 - _cy) : dy / _span(1 + _cy));
    vx = vx.clamp(-1.0, 1.0);
    vy = vy.clamp(-1.0, 1.0);
    var r = math.sqrt(vx * vx + vy * vy);
    if (r > 1) {
      vx /= r;
      vy /= r;
      r = 1;
    }
    final dz = deadZone.clamp(0.0, 0.95);
    if (r <= dz) return const [0.0, 0.0];
    final k = (r - dz) / (1 - dz) / r;
    return [vx * k, vy * k];
  }

  static double _span(double v) => v < 1e-3 ? 1e-3 : v;
}
