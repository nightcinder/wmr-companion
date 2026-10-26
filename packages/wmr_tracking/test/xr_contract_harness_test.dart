import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

String _read(String name) => File('test/fixtures/$name').readAsStringSync();

XrContractFixture _fixture(String stem) => XrContractFixture(
  name: stem,
  nativeJson: _read('xr_contract_native_${stem}_frame.json'),
  unityJson: _read('xr_contract_unity_${stem}_frame.json'),
);

const _codec = TrackingFrameCodec();

void main() {
  test('harness replays both modes at the requested rates, decodes 26 joints '
      'and rejects malformed frames', () {
    final report = const XrContractHarness().run(
      fixtures: [_fixture('head'), _fixture('hand')],
      malformedJson: [
        _read('xr_contract_malformed.json'),
        _read('xr_contract_bad_timestamp.json'),
      ],
    );

    expect(report.passes, isTrue, reason: report.failures.join('\n'));
    expect(report.malformedRejected, isTrue);
    expect(report.malformedChecked, 2);
    expect(report.modes, hasLength(2));
    for (final mode in report.modes) {
      expect(mode.head.hz, closeTo(60, 0.5));
      expect(mode.hands.hz, closeTo(30, 0.5));
      expect(mode.frames, 61);
      expect(mode.handFrames, 31);
      expect(mode.jointsPerHand, 26);
    }
  });

  test(
    'golden head and hand fixtures agree between native and Unity modes',
    () {
      final unityHand = const UnityRelayFrameCodec(
        defaultSpace: UnityRelayCoordinateSpace.unity,
      ).decodeString(_read('xr_contract_unity_hand_frame.json'));
      final nativeHand = _codec.decodeString(
        _read('xr_contract_native_hand_frame.json'),
      );

      expect(nativeHand.head!.pose.translation, Vector3(0, 1.6, -0.05));
      expect(unityHand.head!.pose.translation, Vector3(0, 1.6, -0.05));
      for (final hand in TrackedHand.values) {
        expect(nativeHand.hand(hand)!.joints, hasLength(26));
        expect(
          nativeHand.hand(hand)!.joints[HandJoint.palm]!.pose.translation,
          unityHand.hand(hand)!.joints[HandJoint.palm]!.pose.translation,
        );
      }
      expect(
        nativeHand.rightHand!.joints[HandJoint.palm]!.pose.translation,
        Vector3(0.18, 1.2, -0.35),
      );
    },
  );

  test('harness fails when a malformed fixture is accepted', () {
    final report = const XrContractHarness().run(
      fixtures: [_fixture('head'), _fixture('hand')],
      malformedJson: [_read('xr_contract_native_head_frame.json')],
    );

    expect(report.passes, isFalse);
    expect(report.malformedRejected, isFalse);
    expect(report.failures, hasLength(2));
  });

  test('Unity relay frames decode through RelayTrackingSource', () async {
    final messages = StreamController<Object?>();
    final source = RelayTrackingSource(
      messages: messages.stream,
      defaultSpace: UnityRelayCoordinateSpace.unity,
    );
    final first = Completer<TrackingFrame>();
    final subscription = source.frames.listen((frame) {
      if (!first.isCompleted) first.complete(frame);
    });
    await source.start();
    messages.add(_read('xr_contract_unity_hand_frame.json'));

    final frame = await first.future;
    expect(frame.head!.pose.translation, Vector3(0, 1.6, -0.05));
    expect(frame.rightHand!.joints, hasLength(26));

    await subscription.cancel();
    await messages.close();
    await source.dispose();
  });

  test('fake adapter counts scales with rate and rejects bad rates', () {
    final adapter = FakeXrAdapter(headRateHz: 90, handRateHz: 30);
    expect(adapter.headFrameCount, 91);
    expect(adapter.handFrameCount, 31);
    expect(
      adapter.frames().where((frame) => frame.rightHand != null),
      hasLength(31),
    );

    expect(
      () => FakeXrAdapter(headRateHz: 60, handRateHz: 40),
      throwsArgumentError,
    );
  });
}
