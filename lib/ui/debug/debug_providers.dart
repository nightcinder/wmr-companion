import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart';

import '../../ble/ble_transport.dart';
import '../../ble/fake_transport.dart';
import '../../ble/fake_wmr_bridge.dart';
import '../../domain/orientation.dart';
import '../../domain/synthetic_motion.dart';
import '../../services/controller_service.dart';
import '../connect/connect_providers.dart';
import 'stream_settings.dart';

/// Where the debug screen takes its data from.
enum DebugSource { fake, real }

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
  final bridge = FakeWmrBridge(
    ref.watch(fakeTransportProvider),
    echoDelay: const Duration(milliseconds: 6),
  )..start();
  ref.onDispose(bridge.stop);
  return bridge;
});

/// The service on the fake transport, in the stream mode chosen in the UI.
final fakeServiceProvider = FutureProvider<ControllerService>((ref) async {
  ref.watch(fakeBridgeProvider);
  final service = ControllerService(
    ref.watch(transportProvider),
    fakeBridgeDeviceId,
    mode: ref.read(streamModeProvider),
    mapping: ref.read(axisMappingProvider),
    filterKind: ref.read(filterKindProvider),
    stickConfig: ref.read(stickConfigProvider),
  );
  applyFf13Settings(service, ref.read(ff13SettingsProvider));
  ref.onDispose(service.dispose);
  ref.listen(axisMappingProvider, (_, m) => service.setMapping(m));
  ref.listen(filterKindProvider, (_, k) => service.setFilterKind(k));
  ref.listen(stickConfigProvider, (_, c) => service.setStickConfig(c));
  ref.listen(ff13SettingsProvider, (_, s) => applyFf13Settings(service, s));
  await service.start();
  return service;
});

/// The service behind [source], or null when there is none yet (fake: still
/// starting; real: not connected).
final controllerServiceProvider =
    Provider.family<ControllerService?, DebugSource>((ref, source) {
      switch (source) {
        case DebugSource.fake:
          return ref.watch(fakeServiceProvider).value;
        case DebugSource.real:
          ref.watch(realDeviceProvider);
          return ref.read(realDeviceProvider.notifier).service;
      }
    });

/// Stream counters, refreshed 4 times a second.
final streamStatsProvider = StreamProvider<StreamStats>((ref) async* {
  final service = await ref.watch(fakeServiceProvider.future);
  yield service.stats;
  yield* Stream.periodic(
    const Duration(milliseconds: 250),
    (_) => service.stats,
  );
});

/// Synthetic orientation for the fake bridge in raw mode, where the app has
/// no IMU data.
final orientationProvider = StreamProvider<Quaternion>((ref) {
  const motion = SyntheticMotion();
  final clock = Stopwatch()..start();
  return Stream.periodic(
    const Duration(milliseconds: 16),
    (_) => motion.at(clock.elapsed),
  );
});

/// What the decoded view shows: the fused orientation of the selected hand
/// and the numbers around it.
class DecodedView {
  const DecodedView({
    required this.orientation,
    required this.stats,
    required this.mode,
    required this.hand,
  });

  final Quaternion orientation;
  final DecodedStats stats;
  final ModeState mode;
  final int hand;
}

/// Orientation at about 30 Hz, stats recomputed a few times a second. Empty
/// until [controllerServiceProvider] has a service.
final decodedViewProvider = StreamProvider.family<DecodedView, DebugSource>((
  ref,
  source,
) {
  final service = ref.watch(controllerServiceProvider(source));
  if (service == null) return const Stream.empty();
  final hand = ref.watch(selectedHandProvider);
  var stats = service.decodedStats;
  return Stream.periodic(const Duration(milliseconds: 33), (n) {
    if (n % 8 == 0) stats = service.decodedStats;
    return DecodedView(
      orientation: service.pipeline(hand).orientation,
      stats: stats,
      mode: service.modeState,
      hand: hand,
    );
  });
});

/// Yaw removed from the displayed orientation ("reset orientation") in the
/// synthetic view. The fused view resets the filter's heading instead.
final yawOffsetProvider = NotifierProvider<YawOffset, double>(YawOffset.new);

class YawOffset extends Notifier<double> {
  @override
  double build() => 0;

  void zeroAt(Quaternion raw) => state = eulerFromQuaternion(raw).yaw;
}
