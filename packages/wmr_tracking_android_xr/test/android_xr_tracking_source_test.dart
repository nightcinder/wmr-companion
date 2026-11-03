import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_tracking_android_xr/wmr_tracking_android_xr.dart';

const _supported = <String, Object?>{
  'supported': true,
  'handTracking': true,
  'headTracking': true,
  'handJointCount': 26,
  'permissions': <String, Object?>{
    'camera': 'granted',
    'sceneUnderstanding': 'granted',
    'handTracking': 'granted',
    'headTracking': 'granted',
  },
};

class _FakePlatform extends AndroidXrTrackingPlatform {
  _FakePlatform({this._capabilities = _supported});

  final Map<String, Object?> _capabilities;
  final StreamController<Object?> messages =
      StreamController<Object?>.broadcast();

  int capabilityCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  Object? capabilityError;
  Object? startError;

  @override
  Future<Map<String, Object?>> capabilities() async {
    capabilityCalls++;
    final error = capabilityError;
    if (error != null) throw error;
    return _capabilities;
  }

  @override
  Future<void> start() async {
    startCalls++;
    final error = startError;
    if (error != null) throw error;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  Stream<Object?> frames() => messages.stream;

  void emit(Object? message) => messages.add(message);
  void emitError(Object error) => messages.addError(error);
}

Map<String, Object?> _frameMap() {
  final joints = <String, Object?>{};
  for (final joint in HandJoint.values) {
    joints[joint.name] = {
      'pose': {
        't': [0.1, 1.2, -0.4],
        'q': [0.0, 0.0, 0.0, 1.0],
      },
      'confidence': 'high',
    };
  }
  return {
    'v': 1,
    'time_ns': 1000000000,
    'head': {
      'pose': {
        't': [0.0, 1.6, 0.0],
        'q': [0.0, 0.0, 0.0, 1.0],
      },
      'confidence': 'high',
    },
    'hands': {
      'right': {'hand': 'right', 'joints': joints},
    },
  };
}

Map<String, Object?> _errorFixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  test('the default-off flag never touches the platform', () async {
    final platform = _FakePlatform();

    final source = await AndroidXrTrackingSource.create(
      enabled: false,
      platform: platform,
    );

    expect(source, isNull);
    expect(platform.capabilityCalls, 0);
    expect(platform.startCalls, 0);
  });

  test('create reports honest 26-joint capabilities', () async {
    final source = await AndroidXrTrackingSource.create(
      enabled: true,
      platform: _FakePlatform(),
    );

    expect(source, isNotNull);
    expect(source!.vendor, TrackingVendor.androidXr);
    expect(source.capabilities.hasHead6Dof, isTrue);
    expect(source.capabilities.hasHandTracking, isTrue);
    expect(source.capabilities.handJointCount, 26);
    expect(
      source.capabilities.supports(TrackingFeature.controllerPose),
      isFalse,
    );
    expect(source.permissions['camera'], 'granted');
    expect(source.permissions['sceneUnderstanding'], 'granted');
    expect(source.permissions['handTracking'], 'granted');
  });

  test(
    'an unsupported device is a typed failure, not an empty source',
    () async {
      final source = AndroidXrTrackingSource.create(
        enabled: true,
        platform: _FakePlatform(
          capabilities: const {
            'supported': false,
            'reason': 'not an XR device',
          },
        ),
      );

      await expectLater(
        source,
        throwsA(
          isA<TrackingException>().having(
            (error) => error.kind,
            'kind',
            TrackingExceptionKind.unsupported,
          ),
        ),
      );
    },
  );

  test('permission denial from the fixture maps to permissionDenied', () async {
    final fixture = _errorFixture('android_xr_permission_denied.json');
    final platform = _FakePlatform()
      ..startError = PlatformException(
        code: fixture['platform_code']! as String,
        message: fixture['message']! as String,
      );
    final source = (await AndroidXrTrackingSource.create(
      enabled: true,
      platform: platform,
    ))!;

    await expectLater(
      source.start(),
      throwsA(
        isA<TrackingException>().having(
          (error) => error.kind,
          'kind',
          TrackingExceptionKind.permissionDenied,
        ),
      ),
    );
    expect(source.started, isFalse);
    expect(platform.stopCalls, 0);
  });

  test('a staged platform error keeps the failing boundary', () async {
    final platform = _FakePlatform()
      ..startError = PlatformException(
        code: 'unavailable',
        message: 'Session.create failed',
        details: const {'stage': 'sessionCreate'},
      );
    final source = (await AndroidXrTrackingSource.create(
      enabled: true,
      platform: platform,
    ))!;

    await expectLater(
      source.start(),
      throwsA(
        isA<TrackingException>()
            .having(
              (error) => error.kind,
              'kind',
              TrackingExceptionKind.unavailable,
            )
            .having((error) => error.stage, 'stage', 'sessionCreate')
            .having(
              (error) => error.toString(),
              'toString',
              contains('stage: sessionCreate'),
            ),
      ),
    );
  });

  test('a refused SPATIAL mode from the fixture maps to unsupported', () async {
    final fixture = _errorFixture('android_xr_spatial_unsupported.json');
    final platform = _FakePlatform()
      ..startError = PlatformException(
        code: fixture['platform_code']! as String,
        message: fixture['message']! as String,
      );
    final source = (await AndroidXrTrackingSource.create(
      enabled: true,
      platform: platform,
    ))!;

    await expectLater(
      source.start(),
      throwsA(
        isA<TrackingException>().having(
          (error) => error.kind,
          'kind',
          TrackingExceptionKind.unsupported,
        ),
      ),
    );
  });

  test('start, stop, restart and dispose are idempotent', () async {
    final platform = _FakePlatform();
    final source = (await AndroidXrTrackingSource.create(
      enabled: true,
      platform: platform,
    ))!;
    final frames = <TrackingFrame>[];
    source.frames.listen(frames.add);

    await source.start();
    await source.start();
    expect(platform.startCalls, 1);

    platform.emit(jsonEncode(_frameMap()));
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));
    expect(frames.first.timeNs, 1000000000);
    expect(frames.first.rightHand!.joints, hasLength(26));

    await source.stop();
    await source.stop();
    expect(platform.stopCalls, 1);
    platform.emit(jsonEncode(_frameMap()));
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));

    await source.start();
    expect(platform.startCalls, 2);

    await source.dispose();
    await source.dispose();
    expect(platform.disposeCalls, 1);
    expect(source.disposed, isTrue);
    await expectLater(source.start(), throwsStateError);
  });

  test(
    'a malformed frame is a protocol error and keeps the stream open',
    () async {
      final platform = _FakePlatform();
      final source = (await AndroidXrTrackingSource.create(
        enabled: true,
        platform: platform,
      ))!;
      final errors = <Object>[];
      final frames = <TrackingFrame>[];
      source.frames.listen(frames.add, onError: errors.add);

      await source.start();
      platform.emit('not json');
      await Future<void>.delayed(Duration.zero);
      platform.emit(jsonEncode(_frameMap()));
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(
        (errors.single as TrackingException).kind,
        TrackingExceptionKind.protocol,
      );
      expect(frames, hasLength(1));
    },
  );

  test(
    'a platform event error is typed and does not close the stream',
    () async {
      final platform = _FakePlatform();
      final source = (await AndroidXrTrackingSource.create(
        enabled: true,
        platform: platform,
      ))!;
      final errors = <Object>[];
      source.frames.listen((_) {}, onError: errors.add);

      await source.start();
      platform.emitError(
        PlatformException(
          code: 'unavailable',
          message: 'tracking service died',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(
        (errors.single as TrackingException).kind,
        TrackingExceptionKind.unavailable,
      );
      expect(source.started, isFalse);

      // The stream stayed open, and start() resubscribes rather than treating
      // the source as still running.
      final frames = <TrackingFrame>[];
      source.frames.listen(frames.add);
      await source.start();
      expect(platform.startCalls, 2);
      platform.emit(jsonEncode(_frameMap()));
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(1));
    },
  );

  test(
    'frames carry the source monotonic timestamp and OpenXR pose order',
    () async {
      final platform = _FakePlatform();
      final source = (await AndroidXrTrackingSource.create(
        enabled: true,
        platform: platform,
      ))!;
      final frames = <TrackingFrame>[];
      source.frames.listen(frames.add);

      await source.start();
      final frame = _frameMap();
      frame['time_ns'] = 42;
      platform.emit(frame);
      await Future<void>.delayed(Duration.zero);

      expect(frames.single.timeNs, 42);
      final pose = frames.single.rightHand!.palmPose!.pose;
      expect(pose.translation.x, 0.1);
      expect(pose.translation.y, 1.2);
      expect(pose.translation.z, -0.4);
      expect(pose.rotation.x, 0);
      expect(pose.rotation.y, 0);
      expect(pose.rotation.z, 0);
      expect(pose.rotation.w, 1);
    },
  );
}
