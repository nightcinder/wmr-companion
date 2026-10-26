import 'dart:io';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

PoseRecording _cliRecording() {
  final builder = PoseRecordingBuilder();
  final left = ControllerPose(
    hand: TrackedHand.left,
    hostTimeNs: 1000,
    orientation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.25),
    position: Vector3(-0.2, -0.25, -0.35),
    source: ControllerPoseSource.handAnchor,
    confidence: TrackingConfidence.high,
  );
  final right = ControllerPose(
    hand: TrackedHand.right,
    hostTimeNs: 1000,
    orientation: Quaternion.identity(),
    source: ControllerPoseSource.orientationOnly,
    confidence: TrackingConfidence.none,
    frameAgeNs: 12000000,
  );
  final tracking = TrackingFrame(
    timeNs: 1000,
    hostTimeNs: 1000,
    head: TrackedPose(
      pose: Pose(
        translation: Vector3(0, 1.6, 0),
        rotation: Quaternion.identity(),
      ),
    ),
    leftHand: HandPose(
      hand: TrackedHand.left,
      palm: TrackedPose(
        pose: Pose(
          translation: Vector3(-0.18, -0.23, -0.29),
          rotation: Quaternion.identity(),
        ),
      ),
    ),
  );
  builder.add(hostTimeNs: 1000, left: left, right: right, tracking: tracking);
  builder.add(
    hostTimeNs: 34000000,
    left: ControllerPose(
      hand: TrackedHand.left,
      hostTimeNs: 34000000,
      orientation: Quaternion.identity(),
      position: Vector3(-0.3, -0.2, -0.35),
      source: ControllerPoseSource.handAnchor,
      confidence: TrackingConfidence.high,
    ),
  );
  return builder.build();
}

void main() {
  test('record then replay is deterministic', () {
    final recording = _cliRecording();
    final encoded = recording.encode();

    final decoded = PoseRecording.decode(encoded);

    expect(decoded.encode(), encoded);
    expect(decoded.samples, hasLength(2));
    expect(decoded.originNs, 1000);
    expect(decoded.duration, const Duration(microseconds: 33999));
    expect(decoded.samples.first.left!.position, Vector3(-0.2, -0.25, -0.35));
    expect(decoded.samples.first.left!.source, ControllerPoseSource.handAnchor);
    expect(decoded.samples.first.right!.frameAgeNs, 12000000);
    expect(decoded.samples.first.tracking!.leftHand!.palm, isNotNull);
    expect(decoded.samples.last.tracking, isNull);

    // Replaying at a time before the second sample keeps the first pose.
    expect(decoded.sampleAt(const Duration(milliseconds: 1))!.hostTimeNs, 1000);
    expect(
      decoded.sampleAt(const Duration(milliseconds: 33))!.hostTimeNs,
      1000,
    );
    expect(decoded.sampleAt(const Duration(seconds: 1))!.hostTimeNs, 34000000);
  });

  test('builder ignores timestamps that do not advance', () {
    final builder = PoseRecordingBuilder();
    ControllerPose pose(int ns) => ControllerPose(
      hand: TrackedHand.left,
      hostTimeNs: ns,
      orientation: Quaternion.identity(),
    );

    expect(builder.add(hostTimeNs: 20, left: pose(20)), isTrue);
    expect(builder.add(hostTimeNs: 20, left: pose(20)), isFalse);
    expect(builder.add(hostTimeNs: 10, left: pose(10)), isFalse);
    expect(builder.add(hostTimeNs: 30, left: pose(30)), isTrue);
    expect(builder.build().samples, hasLength(2));
  });

  group('committed fixture', () {
    test('round-trips byte for byte and replays as a regression vector', () {
      final file = File('test/fixtures/pose_recording_v1.json');
      final text = file.readAsStringSync();

      final recording = PoseRecording.decode(text);

      expect(recording.encode(), text);
      expect(recording.samples, hasLength(3));
      expect(recording.samples[1].left!.confidence, TrackingConfidence.high);
      expect(recording.samples[1].tracking!.head!.pose.translation.y, 1.6);
      expect(recording.samples[2].right!.position, Vector3(0.3, -0.2, -0.35));
      expect(
        recording.sampleAt(const Duration(milliseconds: 34))!.hostTimeNs,
        34000000,
      );
      expect(
        recording.sampleAt(const Duration(milliseconds: 66))!.hostTimeNs,
        34000000,
      );
      expect(
        recording.sampleAt(const Duration(milliseconds: 67))!.hostTimeNs,
        67000000,
      );
    });
  });

  group('malformed input gives typed errors', () {
    PoseRecordingError errorFor(String source) {
      try {
        PoseRecording.decode(source);
      } on PoseRecordingException catch (error) {
        return error.error;
      }
      fail('expected a PoseRecordingException');
    }

    test('invalid JSON', () {
      expect(errorFor('{'), PoseRecordingError.invalidJson);
    });

    test('not a recording document', () {
      expect(
        errorFor('{"format":"something-else","version":1,"samples":[]}'),
        PoseRecordingError.invalidDocument,
      );
    });

    test('unsupported version', () {
      expect(
        errorFor('{"format":"wmr-pose-recording","version":2,"samples":[]}'),
        PoseRecordingError.unsupportedVersion,
      );
    });

    test('out-of-order sample', () {
      expect(
        errorFor(
          '{"format":"wmr-pose-recording","version":1,"samples":['
          '{"host_ns":2},{"host_ns":1}]}',
        ),
        PoseRecordingError.invalidSample,
      );
    });

    test('malformed controller pose', () {
      expect(
        errorFor(
          '{"format":"wmr-pose-recording","version":1,"samples":['
          '{"host_ns":1,"left":{"hand":"left","host_time_ns":1,'
          '"orientation":[0,0,0],"source":"handAnchor",'
          '"confidence":"high"}}]}',
        ),
        PoseRecordingError.invalidPose,
      );
    });

    test('malformed tracking frame', () {
      expect(
        errorFor(
          '{"format":"wmr-pose-recording","version":1,"samples":['
          '{"host_ns":1,"tracking":{"v":2,"time_ns":1}}]}',
        ),
        PoseRecordingError.invalidTrackingFrame,
      );
    });
  });
}
