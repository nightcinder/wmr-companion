import 'dart:convert';

import 'fusion.dart';
import 'tracking_types.dart';

/// Why a pose recording could not be decoded.
enum PoseRecordingError {
  /// The file is not valid JSON.
  invalidJson,

  /// The document is JSON but not a pose recording.
  invalidDocument,

  /// The document uses a version this build does not read.
  unsupportedVersion,

  /// A sample is missing fields or is out of order.
  invalidSample,

  /// A controller pose in a sample is malformed.
  invalidPose,

  /// A tracking frame in a sample is malformed.
  invalidTrackingFrame,
}

/// Typed error thrown by [PoseRecording.decode].
///
/// The [error] kind lets the UI say what is wrong without parsing a message.
class PoseRecordingException implements Exception {
  const PoseRecordingException(this.error, this.message, [this.cause]);

  final PoseRecordingError error;
  final String message;

  /// The underlying [FormatException] for pose/frame errors, when there is one.
  final Object? cause;

  @override
  String toString() => 'PoseRecordingException(${error.name}): $message';
}

/// One viewer tick: the fused controller poses and the tracking frame that
/// produced them.
///
/// [left] and [right] are optional so a recording can start before the first
/// controller sample or contain tracking-only frames.
class PoseRecordingSample {
  const PoseRecordingSample({
    required this.hostTimeNs,
    this.left,
    this.right,
    this.tracking,
  });

  /// Host monotonic timestamp in nanoseconds, matching
  /// [ControllerPose.hostTimeNs].
  final int hostTimeNs;

  final ControllerPose? left;
  final ControllerPose? right;

  /// The tracking frame delivered at this tick, if any.
  final TrackingFrame? tracking;

  ControllerPose? forHand(TrackedHand hand) =>
      hand == TrackedHand.left ? left : right;

  Map<String, Object?> toJson() => {
    'host_ns': hostTimeNs,
    if (left != null) 'left': left!.toJson(),
    if (right != null) 'right': right!.toJson(),
    if (tracking != null) 'tracking': tracking!.toJson(),
  };
}

/// A versioned JSON recording of [ControllerPose]s plus [TrackingFrame]s.
///
/// The document is stable, diffable and deterministic: [encode] of the same
/// recording always produces the same bytes, and encoding a decoded recording
/// reproduces the input. That makes committed recordings usable as regression
/// vectors.
///
/// Version 1 shape:
///
/// ```json
/// {
///   "format": "wmr-pose-recording",
///   "version": 1,
///   "samples": [
///     {
///       "host_ns": 1000,
///       "left": {"hand": "left", "host_time_ns": 1000, ...},
///       "right": {"hand": "right", "host_time_ns": 1000, ...},
///       "tracking": {"v": 1, "time_ns": 1000, ...}
///     }
///   ]
/// }
/// ```
class PoseRecording {
  PoseRecording({required List<PoseRecordingSample> samples})
    : samples = List.unmodifiable(samples);

  /// The format tag written to and required from every document.
  static const String format = 'wmr-pose-recording';

  /// The newest version this build reads and writes.
  static const int currentVersion = 1;

  final List<PoseRecordingSample> samples;

  bool get isEmpty => samples.isEmpty;

  /// Timestamp of the first sample, or zero for an empty recording.
  int get originNs => samples.isEmpty ? 0 : samples.first.hostTimeNs;

  /// Last sample time relative to [originNs].
  Duration get duration => samples.isEmpty
      ? Duration.zero
      : Duration(
          microseconds: ((samples.last.hostTimeNs - originNs) / 1000).round(),
        );

  /// The newest sample at or before [offset] from [originNs].
  ///
  /// Playback is a step function rather than interpolation, so every replayed
  /// tick is exactly one recorded sample.
  PoseRecordingSample? sampleAt(Duration offset) {
    if (samples.isEmpty) return null;
    final target = originNs + offset.inMicroseconds * 1000;
    if (target < samples.first.hostTimeNs) return samples.first;
    var low = 0;
    var high = samples.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (samples[mid].hostTimeNs <= target) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return samples[low];
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'version': currentVersion,
    'samples': [for (final sample in samples) _stable(sample.toJson())],
  };

  /// Deterministic pretty JSON, suitable for committing after review.
  ///
  /// Floating-point values are rounded to nine decimals before writing. That
  /// is well below sensor resolution and makes a decoded recording re-encode
  /// to the same bytes, even though [Pose] normalises quaternions again on
  /// decode.
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Parses a recording, throwing [PoseRecordingException] on bad input.
  factory PoseRecording.decode(String source) {
    Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (error) {
      throw PoseRecordingException(
        PoseRecordingError.invalidJson,
        'not valid JSON: ${error.message}',
        error,
      );
    }
    return PoseRecording.fromJson(json);
  }

  /// Parses an already-decoded document, throwing [PoseRecordingException].
  factory PoseRecording.fromJson(Object? json) {
    if (json is! Map) {
      throw const PoseRecordingException(
        PoseRecordingError.invalidDocument,
        'recording must be a JSON object',
      );
    }
    if (json['format'] != format) {
      throw PoseRecordingException(
        PoseRecordingError.invalidDocument,
        'format must be "$format"',
      );
    }
    final version = json['version'];
    if (version != currentVersion) {
      throw PoseRecordingException(
        PoseRecordingError.unsupportedVersion,
        'unsupported recording version: $version',
      );
    }
    final rawSamples = json['samples'];
    if (rawSamples is! List) {
      throw const PoseRecordingException(
        PoseRecordingError.invalidDocument,
        'samples must be a list',
      );
    }

    final samples = <PoseRecordingSample>[];
    for (var index = 0; index < rawSamples.length; index++) {
      final sample = _sample(rawSamples[index], index);
      if (samples.isNotEmpty && sample.hostTimeNs <= samples.last.hostTimeNs) {
        throw PoseRecordingException(
          PoseRecordingError.invalidSample,
          'sample $index is not newer than the previous sample',
        );
      }
      samples.add(sample);
    }
    return PoseRecording(samples: samples);
  }

  static PoseRecordingSample _sample(Object? json, int index) {
    if (json is! Map) {
      throw PoseRecordingException(
        PoseRecordingError.invalidSample,
        'sample $index must be an object',
      );
    }
    final hostNs = json['host_ns'];
    if (hostNs is! int || hostNs < 0) {
      throw PoseRecordingException(
        PoseRecordingError.invalidSample,
        'sample $index host_ns must be a non-negative integer',
      );
    }
    ControllerPose? pose(String key, TrackedHand hand) {
      final value = json[key];
      if (value == null) return null;
      try {
        final decoded = ControllerPose.fromJson(value);
        if (decoded.hand != hand) {
          throw FormatException('$key pose must be for ${hand.name}');
        }
        return decoded;
      } on FormatException catch (error) {
        throw PoseRecordingException(
          PoseRecordingError.invalidPose,
          'sample $index $key: ${error.message}',
          error,
        );
      }
    }

    TrackingFrame? tracking;
    final rawTracking = json['tracking'];
    if (rawTracking != null) {
      try {
        tracking = TrackingFrame.fromJson(rawTracking);
      } on FormatException catch (error) {
        throw PoseRecordingException(
          PoseRecordingError.invalidTrackingFrame,
          'sample $index tracking: ${error.message}',
          error,
        );
      }
    }

    return PoseRecordingSample(
      hostTimeNs: hostNs,
      left: pose('left', TrackedHand.left),
      right: pose('right', TrackedHand.right),
      tracking: tracking,
    );
  }
}

/// Collects live viewer ticks into a [PoseRecording].
///
/// [add] ignores a tick that is not newer than the previous one, so a burst of
/// duplicate timestamps cannot break the recording. The decoded format stays
/// strictly increasing.
class PoseRecordingBuilder {
  final List<PoseRecordingSample> _samples = [];

  int get length => _samples.length;

  /// Returns whether the sample was kept.
  bool add({
    required int hostTimeNs,
    ControllerPose? left,
    ControllerPose? right,
    TrackingFrame? tracking,
  }) {
    if (_samples.isNotEmpty && hostTimeNs <= _samples.last.hostTimeNs) {
      return false;
    }
    _samples.add(
      PoseRecordingSample(
        hostTimeNs: hostTimeNs,
        left: left,
        right: right,
        tracking: tracking,
      ),
    );
    return true;
  }

  PoseRecording build() => PoseRecording(samples: _samples);
}

/// Rounds doubles in a JSON-shaped value so re-encoding is byte stable.
Object? _stable(Object? value) {
  if (value is double) {
    return double.parse(value.toStringAsFixed(9));
  }
  if (value is List) {
    return [for (final item in value) _stable(item)];
  }
  if (value is Map) {
    return {for (final entry in value.entries) entry.key: _stable(entry.value)};
  }
  return value;
}
