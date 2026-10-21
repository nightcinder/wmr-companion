import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart';

import '../../ble/ble_transport.dart';
import '../../ble/fake_transport.dart';
import '../../ble/fake_wmr_bridge.dart';
import '../../domain/orientation.dart';
import '../../domain/synthetic_motion.dart';
import '../../services/controller_service.dart';

/// Milestone 1 runs entirely on the fake transport.
final fakeTransportProvider = Provider<FakeTransport>((ref) {
  final transport = FakeTransport(devices: const [fakeBridgeDevice]);
  ref.onDispose(transport.dispose);
  return transport;
});

final transportProvider = Provider<BleTransport>(
  (ref) => ref.watch(fakeTransportProvider),
);

final fakeBridgeProvider = Provider<FakeWmrBridge>((ref) {
  final bridge = FakeWmrBridge(ref.watch(fakeTransportProvider))..start();
  ref.onDispose(bridge.stop);
  return bridge;
});

/// Stream counters, refreshed 4 times a second.
final streamStatsProvider = StreamProvider<StreamStats>((ref) async* {
  ref.watch(fakeBridgeProvider);
  final service = ControllerService(
    ref.watch(transportProvider),
    fakeBridgeDeviceId,
  );
  ref.onDispose(service.dispose);
  await service.start();
  yield service.stats;
  yield* Stream.periodic(
    const Duration(milliseconds: 250),
    (_) => service.stats,
  );
});

/// Synthetic until the app decodes and fuses IMU data from the frames.
final orientationProvider = StreamProvider<Quaternion>((ref) {
  const motion = SyntheticMotion();
  final clock = Stopwatch()..start();
  return Stream.periodic(
    const Duration(milliseconds: 16),
    (_) => motion.at(clock.elapsed),
  );
});

/// Yaw removed from the displayed orientation ("reset orientation").
final yawOffsetProvider = NotifierProvider<YawOffset, double>(YawOffset.new);

class YawOffset extends Notifier<double> {
  @override
  double build() => 0;

  void zeroAt(Quaternion raw) => state = eulerFromQuaternion(raw).yaw;
}
