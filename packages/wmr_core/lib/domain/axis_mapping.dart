import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:wmr_fusion/wmr_fusion.dart' as fusion;

/// View frame axes: X right, Y up, Z toward the viewer (the 3D debug view).
const int axisX = 0;
const int axisY = 1;
const int axisZ = 2;

/// Maps the controller's sensor axes (as carried by FF12: gyro and accel in
/// raw sensor axes, no remapping in the firmware) onto the view frame.
///
/// `view[i] = sign[i] * sensor[source[i]]`, then the flips on top:
/// - [flip]: negate view axis i for both gyro and accel;
/// - [gyroFlip]: additionally negate view axis i for the gyro only.
///
/// Default, from raw-frame captures (docs/PROTOCOL.md, "Axis mapping"):
/// X = -sensor Y, Y = +sensor X, Z = +sensor Z. That is a proper rotation
/// (determinant +1). The sign of the vertical axis (view Y) is the one the
/// twist test left unverified; the flips exist so a backwards axis is one
/// toggle, no rebuild.
///
/// A [flip] on one or three axes makes the frame left-handed. Gyro and accel
/// are then inconsistent with each other (the filter fights itself), so use
/// [flip] for an axis that is wrong in both and [gyroFlip] when only the
/// rotation sense is wrong.
class AxisMapping {
  const AxisMapping({
    this.source = const [1, 0, 2],
    this.sign = const [-1, 1, 1],
    this.flip = const [false, false, false],
    this.gyroFlip = const [false, false, false],
  });

  static const AxisMapping defaultMapping = AxisMapping();

  /// For each view axis, the sensor axis (0 x, 1 y, 2 z) it reads.
  final List<int> source;

  /// For each view axis, +1 or -1.
  final List<int> sign;
  final List<bool> flip;
  final List<bool> gyroFlip;

  /// Whether [source] is a permutation of 0, 1, 2.
  bool get isValid =>
      source.toSet().length == 3 && source.every((s) => s >= 0 && s <= 2);

  AxisMapping withFlip(int viewAxis, bool value) => AxisMapping(
    source: source,
    sign: sign,
    flip: _with(flip, viewAxis, value),
    gyroFlip: gyroFlip,
  );

  AxisMapping withGyroFlip(int viewAxis, bool value) => AxisMapping(
    source: source,
    sign: sign,
    flip: flip,
    gyroFlip: _with(gyroFlip, viewAxis, value),
  );

  static List<bool> _with(List<bool> l, int i, bool v) => [
    for (var k = 0; k < 3; k++) k == i ? v : l[k],
  ];

  double _accelFactor(int viewAxis) =>
      sign[viewAxis] * (flip[viewAxis] ? -1.0 : 1.0);

  double _gyroFactor(int viewAxis) =>
      _accelFactor(viewAxis) * (gyroFlip[viewAxis] ? -1.0 : 1.0);

  /// Sensor-axis gyro (rad/s) in the view frame.
  vm.Vector3 gyroToView(List<double> g) => vm.Vector3(
    _gyroFactor(axisX) * g[source[axisX]],
    _gyroFactor(axisY) * g[source[axisY]],
    _gyroFactor(axisZ) * g[source[axisZ]],
  );

  /// Sensor-axis accel (m/s^2) in the view frame.
  vm.Vector3 accelToView(List<double> a) => vm.Vector3(
    _accelFactor(axisX) * a[source[axisX]],
    _accelFactor(axisY) * a[source[axisY]],
    _accelFactor(axisZ) * a[source[axisZ]],
  );

  @override
  String toString() {
    String term(int i) {
      final f = _accelFactor(i);
      return '${f < 0 ? '-' : '+'}${'xyz'[source[i]]}';
    }

    return 'X=${term(0)} Y=${term(1)} Z=${term(2)}';
  }
}

/// View frame (X right, Y up, Z toward the viewer) to the filter frame
/// (right-handed, +z up): x = X, y = -Z, z = Y.
fusion.Vector3 viewToFilter(vm.Vector3 v) => fusion.Vector3(v.x, -v.z, v.y);

/// Filter-frame orientation (body to world, +z up) as a view-frame
/// quaternion: q_view = C q C^-1 with C the rotation of -90 degrees about X
/// that takes filter axes to view axes.
vm.Quaternion filterToViewOrientation(fusion.Quaternion q) {
  final c = vm.Quaternion.axisAngle(
    vm.Vector3(1, 0, 0),
    -3.141592653589793 / 2,
  );
  final qv = vm.Quaternion(q.x, q.y, q.z, q.w);
  return c * qv * c.conjugated();
}
