import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_fusion/wmr_fusion.dart' as fusion;

import '../protocol/decoded_record.dart';
import 'axis_mapping.dart';
import 'gyro_bias.dart';
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
  }) : timer = timer ?? TickTimer(),
       bias = bias ?? GyroBiasEstimator(),
       _kind = kind,
       _filter = _makeFilter(kind, maxDt);

  /// Live-editable: the next sample uses the new mapping.
  AxisMapping mapping;
  final double maxDt;
  final TickTimer timer;
  final GyroBiasEstimator bias;

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
  }

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
