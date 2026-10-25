import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_tracking_viture/wmr_tracking_viture.dart';

const _supportedLumaUltra = <String, Object?>{
  'unityAvailable': true,
  'supported': true,
  'handTracking': true,
  'headTracking': true,
  'handGestures': true,
  'passthroughCamera': true,
  'handJointCount': 26,
  'glassesModel': 'LumaUltra',
  'permissions': <String, Object?>{'camera': 'granted'},
};

class _FakeViturePlatform extends VitureTrackingPlatform {
  _FakeViturePlatform({this._capabilities = _supportedLumaUltra});

  final Map<String, Object?> _capabilities;
  final StreamController<Object?> messages =
      StreamController<Object?>.broadcast();
  final List<UnityRelayCommand> sentCommands = <UnityRelayCommand>[];

  int capabilityCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  VitureHandFilterMode? lastFilterMode;
  VitureAimSensitivity? lastAimSensitivity;
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
  Future<void> start({
    VitureHandFilterMode filterMode = VitureHandFilterMode.responsive,
    VitureAimSensitivity aimSensitivity = VitureAimSensitivity.high,
  }) async {
    startCalls++;
    lastFilterMode = filterMode;
    lastAimSensitivity = aimSensitivity;
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
  Future<void> sendCommand(UnityRelayCommand command) async {
    sentCommands.add(command);
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
    final platform = _FakeViturePlatform();

    final source = await VitureNeckbandTrackingSource.create(
      enabled: false,
      platform: platform,
    );

    expect(source, isNull);
    expect(platform.capabilityCalls, 0);
    expect(platform.startCalls, 0);
  });

  test('create reports honest Luma Ultra 26-joint capabilities', () async {
    final source = await VitureNeckbandTrackingSource.create(
      enabled: true,
      platform: _FakeViturePlatform(),
    );

    expect(source, isNotNull);
    expect(source!.vendor, TrackingVendor.viture);
    expect(source.glassesModel, VitureGlassesModel.lumaUltra);
    expect(source.capabilities.hasHead6Dof, isTrue);
    expect(source.capabilities.hasHandTracking, isTrue);
    expect(source.capabilities.handJointCount, 26);
    expect(
      source.capabilities.supports(TrackingFeature.controllerPose),
      isFalse,
    );
    expect(source.permissions['camera'], 'granted');
  });

  test(
    '3DoF glasses models never advertise hand tracking or 6DoF head',
    () async {
      for (final model in [
        VitureGlassesModel.one,
        VitureGlassesModel.oneLite,
        VitureGlassesModel.pro,
        VitureGlassesModel.pro2,
        VitureGlassesModel.luma,
        VitureGlassesModel.lumaPro,
        VitureGlassesModel.lumaCyber,
        VitureGlassesModel.beast,
      ]) {
        expect(model.supports6DofHead, isFalse, reason: model.sdkName);
        expect(model.supportsHandTracking, isFalse, reason: model.sdkName);
        expect(
          model.capabilities.hasHandTracking,
          isFalse,
          reason: model.sdkName,
        );
        expect(model.capabilities.hasHead6Dof, isFalse, reason: model.sdkName);
        expect(model.capabilities.handJointCount, 0, reason: model.sdkName);
      }

      final fixture = _fixture('viture_luma_3dof_unsupported.json');
      await expectLater(
        VitureNeckbandTrackingSource.create(
          enabled: true,
          platform: _FakeViturePlatform(capabilities: fixture),
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
    'an unlinked Unity UaaL runtime maps to TrackingExceptionKind.unavailable',
    () async {
      final fixture = _fixture('viture_unity_unavailable.json');

      await expectLater(
        VitureNeckbandTrackingSource.create(
          enabled: true,
          platform: _FakeViturePlatform(capabilities: fixture),
        ),
        throwsA(
          isA<TrackingException>().having(
            (error) => error.kind,
            'kind',
            TrackingExceptionKind.unavailable,
          ),
        ),
      );
    },
  );

  test(
    'camera permission denial from fixture maps to permissionDenied',
    () async {
      final fixture = _fixture('viture_permission_denied.json');
      final platform = _FakeViturePlatform()
        ..startError = PlatformException(
          code: fixture['platform_code']! as String,
          message: fixture['message']! as String,
        );
      final source = (await VitureNeckbandTrackingSource.create(
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

  test(
    'start, configure, recenter, stop, restart and dispose are idempotent',
    () async {
      final platform = _FakeViturePlatform();
      final source = (await VitureNeckbandTrackingSource.create(
        enabled: true,
        platform: platform,
        filterMode: VitureHandFilterMode.stable,
        aimSensitivity: VitureAimSensitivity.low,
      ))!;
      final frames = <TrackingFrame>[];
      source.frames.listen(frames.add);

      await source.start();
      await source.start();
      expect(platform.startCalls, 1);
      expect(platform.lastFilterMode, VitureHandFilterMode.stable);
      expect(platform.lastAimSensitivity, VitureAimSensitivity.low);

      await source.recenter();
      await source.configure(
        filterMode: VitureHandFilterMode.responsive,
        aimSensitivity: VitureAimSensitivity.high,
      );
      expect(platform.sentCommands.map((c) => c.command), [
        'recenter',
        'configure',
      ]);
      expect(platform.sentCommands.last.options['filter_mode'], 'responsive');
      expect(platform.sentCommands.last.options['aim_sensitivity'], 'high');

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
    },
  );

  test('a malformed frame or non-positive timestamp is a protocol error and '
      'keeps the stream open', () async {
    final platform = _FakeViturePlatform();
    final source = (await VitureNeckbandTrackingSource.create(
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
    platform.emit(jsonEncode(_unitySpaceFrameMap(timeNs: 1000000000)));
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
      final platform = _FakeViturePlatform();
      final source = (await VitureNeckbandTrackingSource.create(
        enabled: true,
        platform: platform,
      ))!;
      final errors = <Object>[];
      source.frames.listen((_) {}, onError: errors.add);

      await source.start();
      platform.emitError(
        PlatformException(
          code: 'unavailable',
          message: 'VITURE host activity was detached',
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
