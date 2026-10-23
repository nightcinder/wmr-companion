import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_fusion/wmr_fusion.dart' as fusion;

import '../protocol/decoded_record.dart';
import 'axis_mapping.dart';
import 'gyro_bias.dart';
import 'imu_calibration.dart';
import 'stick_centre.dart';
import 'tick_timer.dart';

enum FilterKind { madgwick, mahony }

/// Live-tunable gains for the orientation filters.
///
/// One value object covers both filters so a pipeline keeps the other
/// filter's gains while it is not selected. Defaults match the filter
/// constructors except [mahonyKi]: the runtime gyro bias estimator already
/// runs in [HandPipeline], so the filter's own integral starts off.
class FilterTuning {
  const FilterTuning({
    this.beta = 0.05,
    this.mahonyKp = 1.0,
    this.mahonyKi = 0.0,
  });

  /// Madgwick gradient-descent gain (rad/s): larger values trust gravity
  /// more and linear acceleration less.
  final double beta;

  /// Mahony proportional gain (1/s) pulling toward gravity.
  final double mahonyKp;

  /// Mahony integral gain (1/s^2) estimating a constant gyro bias. Zero
  /// leaves the bias estimate to the pipeline.
  final double mahonyKi;

  FilterTuning copyWith({double? beta, double? mahonyKp, double? mahonyKi}) =>
      FilterTuning(
        beta: beta ?? this.beta,
        mahonyKp: mahonyKp ?? this.mahonyKp,
        mahonyKi: mahonyKi ?? this.mahonyKi,
      );

  @override
  bool operator ==(Object other) =>
      other is FilterTuning &&
      other.beta == beta &&
      other.mahonyKp == mahonyKp &&
      other.mahonyKi == mahonyKi;

  @override
  int get hashCode => Object.hash(beta, mahonyKp, mahonyKi);
}

/// One decoded record after timing and fusion.
class DecodedSample {
  const DecodedSample({
    required this.record,
    required this.receivedAtUs,
    required this.step,
    required this.orientation,
    required this.fused,
    this.stick = const [0, 0],
    this.bridgeId = '',
  });

  final DecodedRecord record;

  /// Transport device id of the bridge this record arrived from. Empty only
  /// when a caller built a sample without one (tests or synthetic data).
  final String bridgeId;

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

/// Timing, FF13 calibration, gyro bias, axis mapping and the orientation
/// filter for one hand.
///
/// dt comes from the device ticks (see [TickTimer]), never from arrival
/// time. A dt above [maxDt] skips the filter step (and counts it in
/// [largeDtSkips]): after a long gap the gyro rate over the gap is unknown. A
/// timer discontinuity resets the filter's internal state but keeps its
/// orientation.
///
/// Order of operations for a sample:
///
/// 1. FF13 calibration ([calibration], optional): mix matrix, add bias,
///    inverse Rt (see `ImuCalibration`). Skipped when the record has the
///    CALIBRATED flag set: the firmware already did it.
/// 2. `AxisMapping`: sensor/body axes -> view axes (X right, Y up, Z toward
///    the viewer).
/// 3. Runtime gyro bias estimator (`GyroBiasEstimator`): estimated and
///    subtracted in the frame the gyro is in after step 2 when calibration is
///    on, so the bias and the sample are in the same frame. With calibration
///    off it stays in the sensor frame, exactly as before, and the subtraction
///    happens before the axis map.
///
/// Monado feeds its fusion the calibrated sample in OpenXR coordinates
/// (`P_oxr_*`), which is the app's view frame. This port keeps the existing
/// axis table as the body->view conversion instead of applying Monado's
/// `P_oxr_wmr` flip and then the table (which would rotate twice); see
/// `imu_calibration.dart` for the Monado reference.
class HandPipeline {
  HandPipeline({
    FilterKind kind = FilterKind.madgwick,
    FilterTuning tuning = const FilterTuning(),
    this.mapping = AxisMapping.defaultMapping,
    this.maxDt = 0.1,
    TickTimer? timer,
    GyroBiasEstimator? bias,
    StickNormalizer? stickNormalizer,
  }) : _tuning = tuning,
       timer = timer ?? TickTimer(),
       bias = bias ?? GyroBiasEstimator(),
       stickNormalizer = stickNormalizer ?? StickNormalizer(),
       _kind = kind,
       _filter = _makeFilter(kind, maxDt, tuning);

  /// Live-editable: the next sample uses the new mapping.
  AxisMapping mapping;
  final double maxDt;
  final TickTimer timer;
  final GyroBiasEstimator bias;
  final StickNormalizer stickNormalizer;

  FilterTuning _tuning;

  /// Live-editable filter gains. A change reaches the active filter
  /// immediately, so the next sample uses it.
  FilterTuning get tuning => _tuning;
  set tuning(FilterTuning value) {
    _tuning = value;
    final f = _filter;
    if (f is fusion.MadgwickFilter) f.beta = value.beta;
    if (f is fusion.MahonyFilter) {
      f.kp = value.mahonyKp;
      f.ki = value.mahonyKi;
    }
  }

  /// Madgwick beta; the next sample uses the new value.
  double get beta => _tuning.beta;
  set beta(double value) => tuning = _tuning.copyWith(beta: value);

  /// Mahony Kp; the next sample uses the new value.
  double get mahonyKp => _tuning.mahonyKp;
  set mahonyKp(double value) => tuning = _tuning.copyWith(mahonyKp: value);

  /// Mahony Ki; the next sample uses the new value.
  double get mahonyKi => _tuning.mahonyKi;
  set mahonyKi(double value) => tuning = _tuning.copyWith(mahonyKi: value);

  /// Live-editable: the next sample uses the new settings.
  StickConfig stickConfig = const StickConfig();

  /// FF13 calibration for this hand, or null when it is not applied: the
  /// debug switch is off, no block has been read, or the hand has no
  /// accelerometer/gyro entry. CALIBRATED-flagged records ignore it either
  /// way (the firmware already applied its own calibration).
  ///
  /// Changing it restarts the runtime gyro bias: the estimate is in the frame
  /// the gyro was in, so it does not carry across a frame change.
  ImuCalibration? get calibration => _calibration;
  set calibration(ImuCalibration? value) {
    if (identical(value, _calibration)) return;
    _calibration = value;
    bias.restart();
  }

  ImuCalibration? _calibration;

  /// Gyro magnitude (rad/s, bias removed) above which the controller counts
  /// as being moved, so the stick centre is not learned. A guess.
  static const double stickBusyGyro = 0.3;

  FilterKind _kind;
  fusion.OrientationFilterBase _filter;

  int samples = 0;
  int largeDtSkips = 0;
  int nonFiniteSkips = 0;

  /// Records with the CALIBRATED flag set: the firmware already calibrated
  /// them, so the FF13 calibration is not applied again (version 1 never sets
  /// the flag). The axis table is still applied as before.
  int calibratedFlagged = 0;

  FilterKind get kind => _kind;

  static fusion.OrientationFilterBase _makeFilter(
    FilterKind kind,
    double maxDt,
    FilterTuning tuning,
  ) => switch (kind) {
    FilterKind.madgwick => fusion.MadgwickFilter(
      beta: tuning.beta,
      maxDt: maxDt,
    ),
    // The runtime bias estimator is on, so Ki defaults to 0; the debug
    // screen can still raise it.
    FilterKind.mahony => fusion.MahonyFilter(
      kp: tuning.mahonyKp,
      ki: tuning.mahonyKi,
      maxDt: maxDt,
    ),
  };

  /// Switches the filter, keeping the current orientation and tuning.
  void setFilter(FilterKind kind) {
    if (kind == _kind) return;
    final q = _filter.isInitialized ? _filter.orientation : null;
    _kind = kind;
    _filter = _makeFilter(kind, maxDt, _tuning);
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

  DecodedSample add(DecodedRecord r, int receivedAtUs, {String bridgeId = ''}) {
    samples++;
    if (r.calibrated) calibratedFlagged++;
    final step = timer.advance(r.deviceTicks, r.rxTimeUs);
    var fused = false;

    // CALIBRATED-flagged records are already calibrated by the firmware.
    final cal = r.calibrated ? null : _calibration;
    final gyroSensor = cal == null ? r.gyro : cal.calibrateGyro(r.gyro);
    final accelSensor = cal == null ? r.accel : cal.calibrateAccel(r.accel);

    final finite =
        gyroSensor.every((v) => v.isFinite) &&
        accelSensor.every((v) => v.isFinite);
    if (!finite) {
      nonFiniteSkips++;
    } else {
      switch (step.kind) {
        case TickStepKind.baseline:
          bias.breakWindow();
          _seedIfNeeded(r, cal);
        case TickStepKind.discontinuity:
          bias.breakWindow();
          final q = _filter.isInitialized ? _filter.orientation : null;
          _filter.reset(orientation: q);
          _seedIfNeeded(r, cal);
        case TickStepKind.step:
          final dt = step.dtSeconds;
          if (dt <= 0) break;
          if (dt > maxDt) {
            largeDtSkips++;
            bias.breakWindow();
            break;
          }
          final vm.Vector3 gyro;
          if (cal == null) {
            // Existing path, unchanged: subtract the sensor-frame bias, then
            // map to the view frame.
            bias.add(gyroSensor, accelSensor, dt);
            final b = bias.bias;
            gyro = mapping.gyroToView([
              gyroSensor[0] - b[0],
              gyroSensor[1] - b[1],
              gyroSensor[2] - b[2],
            ]);
          } else {
            // Calibration -> axis map -> runtime bias: the estimator and the
            // subtraction are in the view frame, the frame the filter uses.
            final gyroView = mapping.gyroToView(gyroSensor);
            final accelView = mapping.accelToView(accelSensor);
            bias.add(
              [gyroView.x, gyroView.y, gyroView.z],
              [accelView.x, accelView.y, accelView.z],
              dt,
            );
            final b = bias.bias;
            gyro = vm.Vector3(
              gyroView.x - b[0],
              gyroView.y - b[1],
              gyroView.z - b[2],
            );
          }
          final accel = mapping.accelToView(accelSensor);
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
      bridgeId: bridgeId,
    );
  }

  List<double> _stick(DecodedRecord r, TickStep step) {
    // With FF13 calibration on, the runtime bias is in the view frame, so it
    // cannot be subtracted from the raw sensor gyro here. The threshold is
    // only a motion/no-motion test; the raw bias is small compared to it.
    final useBias = _calibration == null || r.calibrated;
    final b = bias.bias;
    final g = [
      for (var i = 0; i < 3; i++) useBias ? r.gyro[i] - b[i] : r.gyro[i],
    ];
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
  void _seedIfNeeded(DecodedRecord r, ImuCalibration? cal) {
    if (_filter.isInitialized) return;
    final accel = cal == null ? r.accel : cal.calibrateAccel(r.accel);
    _filter.update(
      gyro: fusion.Vector3.zero,
      accel: viewToFilter(mapping.accelToView(accel)),
      dt: 0,
    );
  }
}
