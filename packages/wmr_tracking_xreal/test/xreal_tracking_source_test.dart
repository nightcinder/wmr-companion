import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_tracking_xreal/wmr_tracking_xreal.dart';

const _supportedAir2Ultra = <String, Object?>{
  'unityAvailable': true,
  'supported': true,
  'handTracking': true,
  'headTracking': true,
  'handGestures': true,
  'passthroughCamera': true,
  'handJointCount': 26,
  'glassesModel': 'Air2Ultra',
  'permissions': <String, Object?>{'camera': 'granted'},
};

class _FakeXrealPlatform extends XrealTrackingPlatform {
  _FakeXrealPlatform({this._capabilities = _supportedAir2Ultra});

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

Map<String, Object?> _unitySpaceFrameMap({int timeNs = 1000000000}) {
  final joints = <String, Object?>{};
  for (final name in UnityXrHandJoints.unityJointNames) {
    joints[name] = {
      'pose': {
        't': [0.2, 1.21, 0.36],
        'q': [0.1, -0.2, 0.3, 0.9273618495495704],
      },
      'confidence': 'high',
    };
  }
  return {
    'v': 1,
    'space': 'unity',
    'time_ns': timeNs,
    'head': {
      'pose': {
        't': [0.0, 1.6, 0.1],
        'q': [0.0, 0.0, 0.0, 1.0],
      },
      'confidence': 'high',
    },
    'hands': {
      'right': {'hand': 'right', 'joints': joints},
    },
  };
}

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  test('the default-off flag never touches the platform', () async {
    final platform = _FakeXrealPlatform();

    final source = await XrealAir2UltraTrackingSource.create(
      enabled: false,
      platform: platform,
    );

    expect(source, isNull);
    expect(platform.capabilityCalls, 0);
    expect(platform.startCalls, 0);
  });

  test('create reports honest Air 2 Ultra 26-joint capabilities', () async {
    final source = await XrealAir2UltraTrackingSource.create(
      enabled: true,
      platform: _FakeXrealPlatform(),
    );

    expect(source, isNotNull);
    expect(source!.vendor, TrackingVendor.xreal);
    expect(source.glassesModel, XrealGlassesModel.air2Ultra);
    expect(source.capabilities.hasHead6Dof, isTrue);
    expect(source.capabilities.hasHandTracking, isTrue);
    expect(source.capabilities.handJointCount, 26);
    expect(
      source.capabilities.supports(TrackingFeature.controllerPose),
      isFalse,
    );
    expect(source.permissions['camera'], 'granted');
  });

  test('non-Air-2-Ultra glasses never advertise hand tracking', () async {
    for (final model in [
      XrealGlassesModel.one,
      XrealGlassesModel.onePro,
      XrealGlassesModel.air,
      XrealGlassesModel.air2,
      XrealGlassesModel.air2Pro,
      XrealGlassesModel.light,
    ]) {
      expect(model.supportsHandTracking, isFalse, reason: model.sdkName);
      expect(
        model.capabilities.hasHandTracking,
        isFalse,
        reason: model.sdkName,
      );
      expect(model.capabilities.handJointCount, 0, reason: model.sdkName);
    }

    expect(XrealGlassesModel.one.supports6DofHead, isTrue);
    expect(XrealGlassesModel.one.capabilities.hasHead6Dof, isTrue);
    expect(XrealGlassesModel.air2.capabilities.hasHead6Dof, isFalse);
    expect(
      XrealGlassesModel.air2.capabilities.supports(
        TrackingFeature.headPose3Dof,
      ),
      isTrue,
    );
  });

  test('XREAL One + Eye capabilities are refused as unsupported', () async {
    final fixture = _fixture('xreal_one_eye_unsupported.json');

    await expectLater(
      XrealAir2UltraTrackingSource.create(
        enabled: true,
        platform: _FakeXrealPlatform(capabilities: fixture),
      ),
      throwsA(
        isA<TrackingException>()
            .having(
              (error) => error.kind,
              'kind',
              TrackingExceptionKind.unsupported,
            )
            .having(
              (error) => error.message,
              'message',
              contains('Air 2 Ultra'),
            ),
      ),
    );
  });

  test('3DoF Air 2 capabilities are refused as unsupported', () async {
    final fixture = _fixture('xreal_air2_3dof_unsupported.json');

    await expectLater(
      XrealAir2UltraTrackingSource.create(
        enabled: true,
        platform: _FakeXrealPlatform(capabilities: fixture),
      ),
      throwsA(
        isA<TrackingException>().having(
          (error) => error.kind,
          'kind',
          TrackingExceptionKind.unsupported,
        ),
      ),
    );
  });

  test(
    'capabilities that report no support are refused as unsupported',
    () async {
      const unknownCapabilities = <String, Object?>{
        'unityAvailable': true,
        'supported': false,
        'handTracking': false,
        'headTracking': false,
        'handGestures': false,
        'passthroughCamera': false,
        'handJointCount': 0,
        'glassesModel': 'Unknown',
        'reason': 'XREAL hand tracking requires Air 2 Ultra (found Unknown)',
        'permissions': <String, Object?>{'camera': 'granted'},
      };

      await expectLater(
        XrealAir2UltraTrackingSource.create(
          enabled: true,
          platform: _FakeXrealPlatform(capabilities: unknownCapabilities),
        ),
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

  test(
    'an unreported model defers the check to the Unity start handshake',
    () async {
      const pendingCapabilities = <String, Object?>{
        'unityAvailable': true,
        'modelReported': false,
        'supported': true,
        'handTracking': true,
        'headTracking': true,
        'handGestures': true,
        'passthroughCamera': true,
        'handJointCount': 26,
        'glassesModel': 'Unknown',
        'reason': null,
        'permissions': <String, Object?>{'camera': 'granted'},
      };
      final platform = _FakeXrealPlatform(capabilities: pendingCapabilities);

      final source = await XrealAir2UltraTrackingSource.create(
        enabled: true,
        platform: platform,
      );

      expect(source, isNotNull);
      expect(source!.glassesModel, XrealGlassesModel.unknown);
      expect(source.capabilities.hasHead6Dof, isTrue);
      expect(source.capabilities.hasHandTracking, isTrue);
      expect(source.capabilities.handJointCount, 26);
      await source.start();
      expect(platform.startCalls, 1);
      await source.dispose();
    },
  );

  test('a reported Unknown model is still rejected', () async {
    final capabilities = Map<String, Object?>.from(_supportedAir2Ultra)
      ..['glassesModel'] = 'Unknown'
      ..['modelReported'] = true;

    await expectLater(
      XrealAir2UltraTrackingSource.create(
        enabled: true,
        platform: _FakeXrealPlatform(capabilities: capabilities),
      ),
      throwsA(
        isA<TrackingException>().having(
          (error) => error.kind,
          'kind',
          TrackingExceptionKind.unsupported,
        ),
      ),
    );
  });

  test(
    'an unknown model is rejected even when the SDK claims support',
    () async {
      final capabilities = Map<String, Object?>.from(_supportedAir2Ultra)
        ..['glassesModel'] = 'Unknown';

      await expectLater(
        XrealAir2UltraTrackingSource.create(
          enabled: true,
          platform: _FakeXrealPlatform(capabilities: capabilities),
        ),
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

  test('an unlinked Unity UaaL runtime maps to unavailable', () async {
    final fixture = _fixture('xreal_unity_unavailable.json');

    await expectLater(
      XrealAir2UltraTrackingSource.create(
        enabled: true,
        platform: _FakeXrealPlatform(capabilities: fixture),
      ),
      throwsA(
        isA<TrackingException>().having(
          (error) => error.kind,
          'kind',
          TrackingExceptionKind.unavailable,
        ),
      ),
    );
  });

  test(
    'camera permission denial from fixture maps to permissionDenied',
    () async {
      final fixture = _fixture('xreal_permission_denied.json');
      final platform = _FakeXrealPlatform()
        ..startError = PlatformException(
          code: fixture['platform_code']! as String,
          message: fixture['message']! as String,
        );
      final source = (await XrealAir2UltraTrackingSource.create(
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
    },
  );

  test('a staged platform error keeps the failing boundary', () async {
    final platform = _FakeXrealPlatform()
      ..startError = PlatformException(
        code: 'unavailable',
        message: 'XREAL player was detached',
        details: const {'stage': 'detach'},
      );
    final source = (await XrealAir2UltraTrackingSource.create(
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
            .having((error) => error.stage, 'stage', 'detach')
            .having(
              (error) => error.toString(),
              'toString',
              contains('stage: detach'),
            ),
      ),
    );
    expect(source.started, isFalse);
  });

  test('start, stop, restart and dispose are idempotent', () async {
    final platform = _FakeXrealPlatform();
    final source = (await XrealAir2UltraTrackingSource.create(
      enabled: true,
      platform: platform,
    ))!;
    final frames = <TrackingFrame>[];
    source.frames.listen(frames.add);

    await source.start();
    await source.start();
    expect(platform.startCalls, 1);

    platform.emit(jsonEncode(_unitySpaceFrameMap()));
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));
    expect(frames.first.timeNs, 1000000000);
    expect(frames.first.rightHand!.joints, hasLength(26));
    // Unity (0.2, 1.21, 0.36) -> OpenXR (0.2, 1.21, -0.36)
    final palm = frames.first.rightHand!.palmPose!.pose;
    expect(palm.translation.x, closeTo(0.2, 1e-6));
    expect(palm.translation.y, closeTo(1.21, 1e-6));
    expect(palm.translation.z, closeTo(-0.36, 1e-6));
    expect(palm.rotation.x, closeTo(-0.1, 1e-6));
    expect(palm.rotation.y, closeTo(0.2, 1e-6));
    expect(palm.rotation.z, closeTo(0.3, 1e-6));

    await source.stop();
    await source.stop();
    expect(platform.stopCalls, 1);
    platform.emit(jsonEncode(_unitySpaceFrameMap(timeNs: 2000000000)));
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

  test('a malformed frame or non-positive timestamp is a protocol error and '
      'keeps the stream open', () async {
    final platform = _FakeXrealPlatform();
    final source = (await XrealAir2UltraTrackingSource.create(
      enabled: true,
      platform: platform,
    ))!;
    final errors = <Object>[];
    final frames = <TrackingFrame>[];
    source.frames.listen(frames.add, onError: errors.add);

    await source.start();
    platform.emit('not json');
    platform.emit(jsonEncode(_unitySpaceFrameMap(timeNs: 0)));
    await Future<void>.delayed(Duration.zero);
    platform.emit(jsonEncode(_unitySpaceFrameMap()));
    await Future<void>.delayed(Duration.zero);

    expect(errors, hasLength(2));
    for (final error in errors) {
      expect((error as TrackingException).kind, TrackingExceptionKind.protocol);
    }
    expect(frames, hasLength(1));
  });

  test(
    'a platform event error is typed and allows start() to resubscribe',
    () async {
      final platform = _FakeXrealPlatform();
      final source = (await XrealAir2UltraTrackingSource.create(
        enabled: true,
        platform: platform,
      ))!;
      final errors = <Object>[];
      source.frames.listen((_) {}, onError: errors.add);

      await source.start();
      platform.emitError(
        PlatformException(
          code: 'unavailable',
          message: 'XREAL host activity was detached',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(
        (errors.single as TrackingException).kind,
        TrackingExceptionKind.unavailable,
      );
      expect(source.started, isFalse);

      final frames = <TrackingFrame>[];
      source.frames.listen(frames.add);
      await source.start();
      expect(platform.startCalls, 2);
      platform.emit(jsonEncode(_unitySpaceFrameMap()));
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(1));
    },
  );
}
