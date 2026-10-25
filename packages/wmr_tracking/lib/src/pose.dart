import 'package:vector_math/vector_math_64.dart';

/// Rotates [vector] by [rotation] as an active rotation (`q v q*`).
///
/// vector_math's `Quaternion.rotate` applies the inverse rotation, so it must
/// not be used for tracking math. `wmr_core` documents the same trap in
/// `orientation.dart`.
Vector3 rotateVector(Quaternion rotation, Vector3 vector) =>
    rotation.asRotationMatrix().transformed(vector);

/// A rigid transform in a right-handed tracking space.
///
/// The framework uses the OpenXR convention: +X right, +Y up, -Z forward.
/// Vendor SDKs use different conventions (Viture Gen1/Gen2 is
/// North-West-Up, Unity/XREAL is left-handed), so adapters must convert
/// before building a [Pose]. See `docs/TRACKING.md`.
///
/// [translation] is in metres. The rotation is a unit quaternion in Hamilton
/// convention: `rotateVector(rotation, v)` rotates a vector from this pose's
/// local space into its parent space.
class Pose {
  Pose({required Vector3 translation, required Quaternion rotation})
    : translation = Vector3.copy(translation),
      rotation = rotation.normalized();

  /// The identity transform.
  static Pose get identity =>
      Pose(translation: Vector3.zero(), rotation: Quaternion.identity());

  /// Translation in metres in the parent frame.
  final Vector3 translation;

  /// Unit quaternion rotating local-space vectors into the parent frame.
  final Quaternion rotation;

  /// Composition: `a * b` applies [b] first, then [a].
  Pose operator *(Pose other) => Pose(
    translation: translation + rotateVector(rotation, other.translation),
    rotation: rotation * other.rotation,
  );

  /// The inverse transform, such that `pose * pose.inverse()` is identity.
  Pose inverse() {
    final inverseRotation = rotation.conjugated();
    return Pose(
      translation: rotateVector(inverseRotation, -translation),
      rotation: inverseRotation,
    );
  }

  /// Transforms a point from this pose's local space into its parent space.
  Vector3 transformPoint(Vector3 point) =>
      translation + rotateVector(rotation, point);

  /// A copy translated by [offset] in the parent frame.
  Pose translatedBy(Vector3 offset) =>
      Pose(translation: translation + offset, rotation: rotation);

  /// JSON form: translation `[x, y, z]` in metres and rotation
  /// `[x, y, z, w]`, matching vector_math's quaternion component order.
  Map<String, Object?> toJson() => {
    't': [translation.x, translation.y, translation.z],
    'q': [rotation.x, rotation.y, rotation.z, rotation.w],
  };

  /// Parses [Pose.toJson]. Throws [FormatException] on a malformed value.
  factory Pose.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('pose must be an object');
    }
    final t = _three(json['t'], 't');
    final q = _four(json['q'], 'q');
    return Pose(
      translation: Vector3(t[0], t[1], t[2]),
      rotation: Quaternion(q[0], q[1], q[2], q[3]),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Pose &&
      other.translation == translation &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(translation, rotation);

  @override
  String toString() =>
      'Pose(t: $translation, q: ${rotation.x}, ${rotation.y}, '
      '${rotation.z}, ${rotation.w})';
}

List<double> _three(Object? value, String name) {
  if (value is! List || value.length != 3) {
    throw FormatException('$name must contain three numbers');
  }
  return _numbers(value, name);
}

List<double> _four(Object? value, String name) {
  if (value is! List || value.length != 4) {
    throw FormatException('$name must contain four numbers');
  }
  return _numbers(value, name);
}

List<double> _numbers(List<Object?> value, String name) {
  final result = <double>[];
  for (final element in value) {
    if (element is! num) {
      throw FormatException('$name must contain numbers');
    }
    result.add(element.toDouble());
  }
  return result;
}
