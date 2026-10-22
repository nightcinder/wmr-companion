import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_fusion/wmr_fusion.dart' as fusion;

import '../protocol/decoded_record.dart';
import 'axis_mapping.dart';
import 'gyro_bias.dart';
import 'stick_centre.dart';
import 'tick_timer.dart';

enum FilterKind { madgwick, mahony }

/// One decoded record after timing and fusion.
class DecodedSample {
  const DecodedSample({
    required this.record,
    required this.receivedAtUs,
    required this.step,
    required this.orientation,
    required this.fused,
    this.stick = const [0, 0],
  });

  final DecodedRecord record;

  /// Transport monotonic clock when the notification arrived.
  final int receivedAtUs;
  final TickStep step;

  /// View-frame orientation after this sample (X right, Y up, Z toward the
  /// viewer).
  final vm.Quaternion orientation;

  /// Whether this sample advanced the filter.
  final bool fused;

  /// Thumbstick after centre removal and dead zone, -1..1 (x, y).
  final List<double> stick;
}

/// Timing, gyro bias, axis mapping and the orientation filter for one hand.
///
/// dt comes from the device ticks (see [TickTimer]), never from arrival
/// time. A dt above [maxDt] skips the filter step (and counts it in
/// [largeDtSkips]): after a long gap the gyro rate over the gap is unknown. A
/// timer discontinuity resets the filter's internal state but keeps its
/// orientation.
class HandPipeline {
  HandPipeline({
    FilterKind kind = FilterKind.madgwick,
    this.mapping = AxisMapping.defaultMapping,
    this.maxDt = 0.1,
    TickTimer? timer,
    GyroBiasEstimator? bias,
    StickNormalizer? stickNormalizer,
  }) : timer = timer ?? TickTimer(),
       bias = bias ?? GyroBiasEstimator(),
       stickNormalizer = stickNormalizer ?? StickNormalizer(),
       _kind = kind,
       _filter = _makeFilter(kind, maxDt);

  /// Live-editable: the next sample uses the new mapping.
  AxisMapping mapping;
  final double maxDt;
  final TickTimer timer;
  final GyroBiasEstimator bias;
  final StickNormalizer stickNormalizer;

  /// Live-editable: the next sample uses the new settings.
  StickConfig stickConfig = const StickConfig();

  /// Gyro magnitude (rad/s, bias removed) above which the controller counts
  /// as being moved, so the stick centre is not learned. A guess.
  static const double stickBusyGyro = 0.3;

  FilterKind _kind;
  fusion.OrientationFilterBase _filter;

  int samples = 0;
  int largeDtSkips = 0;
  int nonFiniteSkips = 0;

  /// Records with the CALIBRATED flag set: the axis table does not apply to
  /// those (version 1 never sets it).
  int calibratedFlagged = 0;

  FilterKind get kind => _kind;

  static fusion.OrientationFilterBase _makeFilter(
    FilterKind kind,
    double maxDt,
  ) => switch (kind) {
    FilterKind.madgwick => fusion.MadgwickFilter(maxDt: maxDt),
    // The bias is estimated here, so the filter's own integral stays off.
    FilterKind.mahony => fusion.MahonyFilter(ki: 0, maxDt: maxDt),
  };

  /// Switches the filter, keeping the current orientation.
  void setFilter(FilterKind kind) {
    if (kind == _kind) return;
    final q = _filter.isInitialized ? _filter.orientation : null;
    _kind = kind;
    _filter = _makeFilter(kind, maxDt);
    if (q != null) _filter.reset(orientation: q);
  }

  vm.Quaternion get orientation => filterToViewOrientation(_filter.orientation);

  /// Filter updates rejected by the filter itself (bad dt or non-finite).
  int get filterSkips => _filter.skippedUpdates;

  /// Zeroes heading, keeps tilt. Yaw drifts without a magnetometer.
  void resetYaw() => _filter.resetYaw();

  /// Throws the gyro bias away and looks for a new stationary second.
  void recalibrate() => bias.restart();

  /// Call when the stream restarts (reconnect, mode switch): the next record
  /// is a new timing baseline.
  void streamRestarted() {
    timer.rebaseline();
    bias.breakWindow();
    stickNormalizer.breakWindow();
  }

  /// Takes the current stick position as its rest centre.
  void recentreStick() => stickNormalizer.recentre();

  DecodedSample add(DecodedRecord r, int receivedAtUs) {
    samples++;
    if (r.calibrated) calibratedFlagged++;
    final step = timer.advance(r.deviceTicks, r.rxTimeUs);
    var fused = false;

    final finite =
        r.gyro.every((v) => v.isFinite) && r.accel.every((v) => v.isFinite);
    if (!finite) {
      nonFiniteSkips++;
    } else {
      switch (step.kind) {
        case TickStepKind.baseline:
          bias.breakWindow();
          _seedIfNeeded(r);
        case TickStepKind.discontinuity:
          bias.breakWindow();
          final q = _filter.isInitialized ? _filter.orientation : null;
          _filter.reset(orientation: q);
          _seedIfNeeded(r);
        case TickStepKind.step:
          final dt = step.dtSeconds;
          if (dt <= 0) break;
          if (dt > maxDt) {
            largeDtSkips++;
            bias.breakWindow();
            break;
          }
          bias.add(r.gyro, r.accel, dt);
          final b = bias.bias;
          final gyro = mapping.gyroToView([
            r.gyro[0] - b[0],
            r.gyro[1] - b[1],
            r.gyro[2] - b[2],
          ]);
          final accel = mapping.accelToView(r.accel);
          _filter.update(
            gyro: viewToFilter(gyro),
            accel: viewToFilter(accel),
            dt: dt,
          );
          fused = true;
      }
    }
    return DecodedSample(
      record: r,
      receivedAtUs: receivedAtUs,
      step: step,
      orientation: orientation,
      fused: fused,
      stick: _stick(r, step),
    );
  }

  List<double> _stick(DecodedRecord r, TickStep step) {
    final b = bias.bias;
    final g = [for (var i = 0; i < 3; i++) r.gyro[i] - b[i]];
    final rate = math.sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    // Moved or pressed in any other way: buttons, trigger, trackpad, or a
    // gyro rate above the threshold (non-finite counts as moving).
    final busy =
        r.buttons != 0 ||
        r.trigger != 0 ||
        r.trackpad.any((v) => v != 0) ||
        !(rate <= stickBusyGyro);
    return stickNormalizer.process(
      r.stick[0],
      r.stick[1],
      dt: step.kind == TickStepKind.step ? step.dtSeconds : 0,
      busy: busy,
      config: stickConfig,
    );
  }

  /// The filter seeds its tilt from the first usable accel sample and ignores
  /// dt for it.
  void _seedIfNeeded(DecodedRecord r) {
    if (_filter.isInitialized) return;
    _filter.update(
      gyro: fusion.Vector3.zero,
      accel: viewToFilter(mapping.accelToView(r.accel)),
      dt: 0,
    );
  }
}
