import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// The link transport as the app swaps it (BLE -> Wi-Fi -> BLE). Each
/// `BleTransport` owns its own `MonotonicClock`, which is the clock domain the
/// fuser's buffered frames belong to.
final _transportSlotProvider = NotifierProvider<_TransportSlot, BleTransport>(
  _TransportSlot.new,
);

class _TransportSlot extends Notifier<BleTransport> {
  @override
  BleTransport build() {
    final transport = FakeTransport(devices: const [fakeBridgeDevice]);
    ref.onDispose(transport.dispose);
    return transport;
  }

  void replace(BleTransport next) => state = next;
}

class _FixedTracking extends DebugTrackingSourceNotifier {
  _FixedTracking(this.selection);

  final DebugTrackingSelection selection;

  @override
  DebugTrackingSelection build() => selection;
}

TrackingFrame _frame(int hostNs) => TrackingFrame(
  timeNs: hostNs,
  hostTimeNs: hostNs,
  leftHand: HandPose(
    hand: TrackedHand.left,
    palm: TrackedPose(
      pose: Pose(
        translation: Vector3(-0.2, 0, 0),
        rotation: Quaternion.identity(),
      ),
    ),
  ),
);

void main() {
  test('a new link transport starts the fuser on a fresh clock domain', () {
    final source = FakeTrackingSource();
    final container = ProviderContainer(
      overrides: [
        debugTrackingSourceProvider.overrideWith(
          () => _FixedTracking(
            DebugTrackingSelection(
              choice: DebugTrackingSource.viture,
              attachment: AsyncValue.data(
                DebugTrackingAttachment(
                  choice: DebugTrackingSource.viture,
                  source: source,
                ),
              ),
            ),
          ),
        ),
        realLinkTransportProvider.overrideWith(
          (ref) => ref.watch(_transportSlotProvider),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(source.dispose);

    final before = container.read(debugFuserProvider(DebugSource.real));
    expect(before, isNotNull);
    expect(
      identical(container.read(debugFuserProvider(DebugSource.real)), before),
      isTrue,
      reason: 'the same transport keeps the same fuser',
    );

    const oldHostNs = 900000000000;
    before!.onTrackingFrame(_frame(oldHostNs));
    expect(
      before
          .update(
            hand: TrackedHand.left,
            orientation: Quaternion.identity(),
            hostTimeNs: oldHostNs,
          )
          .source,
      isNot(ControllerPoseSource.orientationOnly),
      reason: 'the old fuser has a frame for its clock',
    );

    final nextTransport = FakeTransport(devices: const [fakeBridgeDevice]);
    addTearDown(nextTransport.dispose);
    container.read(_transportSlotProvider.notifier).replace(nextTransport);

    final after = container.read(debugFuserProvider(DebugSource.real));
    expect(after, isNotNull);
    expect(
      identical(after, before),
      isFalse,
      reason: 'a new clock domain must not reuse the old frame buffer',
    );
    expect(
      after!
          .update(
            hand: TrackedHand.left,
            orientation: Quaternion.identity(),
            hostTimeNs: oldHostNs,
          )
          .source,
      ControllerPoseSource.orientationOnly,
    );
  });
}
