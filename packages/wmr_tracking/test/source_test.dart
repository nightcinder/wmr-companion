import 'dart:async';

import 'package:test/test.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

void main() {
  test('the fake source only emits while started', () async {
    final source = FakeTrackingSource();
    final frames = <TrackingFrame>[];
    source.frames.listen(frames.add);

    expect(() => source.addFrame(TrackingFrame(timeNs: 1)), throwsStateError);
    await source.start();
    source.addFrame(TrackingFrame(timeNs: 1));
    await Future<void>.delayed(Duration.zero);
    expect(source.started, isTrue);
    expect(frames, hasLength(1));

    await source.stop();
    expect(() => source.addFrame(TrackingFrame(timeNs: 2)), throwsStateError);

    await source.dispose();
    expect(source.disposed, isTrue);
    expect(() => source.addFrame(TrackingFrame(timeNs: 3)), throwsStateError);
  });

  test('source capabilities describe the feature matrix', () {
    final androidXr = knownTrackingProfiles.firstWhere(
      (profile) => profile.id == 'android-xr-runtime',
    );
    expect(androidXr.vendor, TrackingVendor.androidXr);
    expect(androidXr.capabilities.hasHead6Dof, isTrue);
    expect(androidXr.capabilities.hasHandTracking, isTrue);
    expect(androidXr.capabilities.handJointCount, 26);
    for (final permission in [
      'android.permission.CAMERA',
      'android.permission.SCENE_UNDERSTANDING_COARSE',
      'android.permission.HAND_TRACKING',
      'android.permission.HEAD_TRACKING',
    ]) {
      expect(androidXr.permissions, contains(permission));
    }
    expect(
      androidXr.capabilities.supports(TrackingFeature.controllerPose),
      isFalse,
    );

    final xrealUltra = knownTrackingProfiles.firstWhere(
      (profile) => profile.id == 'xreal-air-2-ultra',
    );
    expect(xrealUltra.capabilities.hasHandTracking, isTrue);
    expect(
      xrealUltra.capabilities.supports(TrackingFeature.passthroughCamera),
      isTrue,
    );

    final xrealOne = knownTrackingProfiles.firstWhere(
      (profile) => profile.id == 'xreal-one-eye',
    );
    expect(xrealOne.capabilities.hasHead6Dof, isTrue);
    expect(xrealOne.capabilities.hasHandTracking, isFalse);

    final rayneo = knownTrackingProfiles.firstWhere(
      (profile) => profile.id == 'rayneo-x3-pro',
    );
    expect(rayneo.vendor, TrackingVendor.rayneo);
    expect(rayneo.capabilities.hasHead6Dof, isTrue);
    expect(rayneo.capabilities.hasHandTracking, isFalse);
    expect(
      rayneo.capabilities.supports(TrackingFeature.passthroughCamera),
      isTrue,
    );

    final rokid = knownTrackingProfiles.firstWhere(
      (profile) => profile.id == 'rokid-ar-studio',
    );
    expect(rokid.vendor, TrackingVendor.rokid);
    expect(rokid.capabilities.hasHead6Dof, isTrue);
    expect(rokid.capabilities.supports(TrackingFeature.handGestures), isTrue);
    expect(rokid.capabilities.hasHandTracking, isFalse);

    final vitureC = knownTrackingProfiles.firstWhere(
      (profile) => profile.id == 'viture-luma-ultra-c',
    );
    expect(vitureC.capabilities.hasHead6Dof, isTrue);
    expect(vitureC.capabilities.hasHandTracking, isFalse);
    expect(vitureC.capabilities.supports(TrackingFeature.stereoCamera), isTrue);

    final vitureUnity = knownTrackingProfiles.firstWhere(
      (profile) => profile.id == 'viture-neckband-unity',
    );
    expect(vitureUnity.capabilities.hasHandTracking, isTrue);
    expect(vitureUnity.capabilities.hasHead6Dof, isTrue);
  });

  test('profile ids are unique and each declares its vendor', () {
    expect(
      knownTrackingProfiles.map((profile) => profile.id).toSet(),
      hasLength(knownTrackingProfiles.length),
    );
    for (final profile in knownTrackingProfiles) {
      expect(profile.capabilities.hasHeadPose, isTrue, reason: profile.id);
      expect(profile.host, isNotEmpty, reason: profile.id);
      expect(profile.integration, isNotEmpty, reason: profile.id);
    }
  });

  test(
    'the relay source decodes maps and strings and reports bad frames',
    () async {
      final messages = StreamController<Object?>();
      final source = RelayTrackingSource(messages: messages.stream);
      final frames = <TrackingFrame>[];
      final errors = <Object>[];
      source.frames.listen(frames.add, onError: errors.add);

      await source.start();
      messages.add({
        'v': 1,
        'time_ns': 1000,
        'head': {
          'pose': {
            't': [0, 1.6, 0],
            'q': [0, 0, 0, 1],
          },
        },
      });
      messages.add(
        '{"v":1,"time_ns":2000,"hands":{"left":{"hand":"left","joints":{}}}}',
      );
      messages.add('not json');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(frames, hasLength(2));
      expect(frames.first.timeNs, 1000);
      expect(frames.last.leftHand!.hand, TrackedHand.left);
      expect(errors, hasLength(1));
      expect(errors.single, isA<TrackingException>());

      await source.dispose();
      await messages.close();
    },
  );
}
