import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/testing.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_tracking_viture/wmr_tracking_viture.dart';

const _bridge = WmrBridgeDevice(id: fakeBridgeDeviceId, name: 'WMR Bridge');
const _methods = MethodChannel('wmr_tracking_viture/methods');

/// Fails if the default-off VITURE flag ever reaches a platform channel.
class _UntouchableViturePlatform extends VitureTrackingPlatform {
  _UntouchableViturePlatform();

  @override
  Future<Map<String, Object?>> capabilities() =>
      throw StateError('capabilities() was called while the flag was off');

  @override
  Future<void> start({
    VitureHandFilterMode filterMode = VitureHandFilterMode.responsive,
    VitureAimSensitivity aimSensitivity = VitureAimSensitivity.high,
  }) => throw StateError('start() was called while the flag was off');

  @override
  Stream<Object?> frames() =>
      throw StateError('frames() was called while the flag was off');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ble_flag_off (VITURE): the default build replays PR #78 3DoF output '
      'and never starts a tracking source', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_methods, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_methods, null),
    );

    expect(VitureTracking.enabled, isFalse);
    final source = await VitureNeckbandTrackingSource.create(
      platform: _UntouchableViturePlatform(),
    );
    expect(source, isNull);
    expect(calls, isEmpty);

    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    final bridge = FakeWmrBridge(transport);
    final companion = WmrCompanion(ble: transport);
    final updates = <WmrControllerUpdate>[];
    final poses = <ControllerPose>[];
    final subs = [
      companion.controllers.listen(updates.add),
      companion.poses.listen(poses.add),
    ];

    await companion.connect(_bridge);
    for (var i = 0; i < 400; i++) {
      bridge.tick();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(updates, hasLength(800));
    expect(poses, isEmpty);
    expect(calls, isEmpty);

    for (final hand in [Hand.left, Hand.right]) {
      final orientation = updates
          .where((update) => update.hand == hand)
          .map((update) => update.orientation)
          .toList();
      expect(orientation, everyElement(isNotNull));

      // Golden samples from c3be059 (PR #78), same deterministic fake
      // bridge replay; the VITURE slice must not change them.
      expect(
        orientation.first,
        _q(0.20881955556139553, 0.0, 0.0, 0.9779541876873075),
      );
      expect(
        orientation[orientation.length ~/ 2],
        _q(
          0.23649147106400764,
          0.31191801945210795,
          0.15984605673848973,
          0.9062164042877461,
        ),
      );
      expect(
        orientation.last,
        _q(
          -0.26989938197304175,
          0.45874772145267173,
          -0.16132621796855015,
          0.8310708171200069,
        ),
      );
    }

    for (final sub in subs) {
      await sub.cancel();
    }
    await companion.dispose();
    await transport.dispose();
    bridge.stop();
  });
}

Matcher _q(double x, double y, double z, double w) => isA<Quaternion>()
    .having((q) => q.x, 'x', closeTo(x, 1e-12))
    .having((q) => q.y, 'y', closeTo(y, 1e-12))
    .having((q) => q.z, 'z', closeTo(z, 1e-12))
    .having((q) => q.w, 'w', closeTo(w, 1e-12));
