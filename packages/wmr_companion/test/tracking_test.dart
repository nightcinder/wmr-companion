import 'dart:async';

import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';

const _bridge = WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge');

class _FailingSource extends FakeTrackingSource {
  @override
  Future<void> start() async {
    throw StateError('no tracking runtime');
  }
}

void main() {
  late FakeTransport transport;
  late FakeWmrBridge fakeBridge;
  late WmrCompanion companion;
  final subs = <StreamSubscription<Object?>>[];

  setUp(() {
    transport = FakeTransport(devices: const [fakeBridgeDevice]);
    fakeBridge = FakeWmrBridge(transport);
    companion = WmrCompanion(ble: transport);
  });

  tearDown(() async {
    for (final sub in subs) {
      await sub.cancel();
    }
    subs.clear();
    await companion.dispose();
    fakeBridge.stop();
    await transport.dispose();
  });

  test('an attached source lifts controller samples to 6DoF poses', () async {
    final source = FakeTrackingSource();
    final poses = <ControllerPose>[];
    subs.add(companion.poses.listen(poses.add));

    await companion.attachTrackingSource(source);
    await companion.connect(_bridge);

    source.addFrame(
      TrackingFrame(
        timeNs: transport.clock.nowUs * 1000,
        head: TrackedPose(
          pose: Pose(
            translation: Vector3(0, 1.6, 0),
            rotation: Quaternion.identity(),
          ),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    for (var i = 0; i < 20; i++) {
      fakeBridge.tick();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(source.started, isTrue);
    expect(poses, isNotEmpty);
    final positioned = poses.where((pose) => pose.hasPosition).toList();
    expect(positioned, isNotEmpty);
    expect(positioned.first.source, ControllerPoseSource.headRelative);
    expect(positioned.first.confidence, TrackingConfidence.low);
    expect(positioned.first.hostTimeNs, greaterThan(0));
    expect(positioned.any((pose) => pose.hand == TrackedHand.left), isTrue);
    expect(positioned.any((pose) => pose.hand == TrackedHand.right), isTrue);
  });

  test('a second attach disposes the first source', () async {
    final first = FakeTrackingSource(id: 'first');
    final second = FakeTrackingSource(id: 'second');

    await companion.attachTrackingSource(first);
    await companion.attachTrackingSource(second);

    expect(first.disposed, isTrue);
    expect(second.started, isTrue);

    await companion.detachTrackingSource();
    expect(second.disposed, isTrue);
  });

  test('a source that cannot start is reported as a typed failure', () async {
    final source = _FailingSource();

    await expectLater(
      companion.attachTrackingSource(source),
      throwsA(isA<WmrTrackingException>()),
    );
    expect(source.disposed, isTrue);
  });

  test('a dispose during attach disposes the new source', () async {
    final source = FakeTrackingSource();

    final attach = companion.attachTrackingSource(source);
    final rejected = expectLater(attach, throwsStateError);
    await companion.dispose();
    await rejected;

    expect(source.disposed, isTrue);
    expect(source.started, isFalse);
  });

  test('attaching after dispose is rejected', () async {
    final source = FakeTrackingSource();
    await companion.dispose();

    await expectLater(companion.attachTrackingSource(source), throwsStateError);
  });
}
