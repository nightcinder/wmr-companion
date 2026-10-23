import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/orientation.dart';
import 'package:wmr_core/domain/synthetic_motion.dart';
import 'package:wmr_core/services/controller_service.dart';

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

/// The BLE link behind [DebugSource], as last reported by the transport.
class LinkStatus {
  const LinkStatus({this.state, this.info});

  /// Null until the transport reports its first state.
  final BleConnectionState? state;

  /// RSSI, MTU and connection interval, only while connected and only when
  /// the platform exposes them.
  final BleConnectionInfo? info;
}

/// Link state and parameters for the debug panel. [BleTransport] has no RSSI
/// stream, so the parameters are read every two seconds; state changes come
/// from [BleTransport.connectionState] immediately. Parameters are dropped
/// while the link is not connected, because [BleTransport.connectionInfo]
/// then fails.
final linkStatusProvider = StreamProvider.family<LinkStatus, DebugSource>((
  ref,
  source,
) {
  final BleTransport transport = source == DebugSource.fake
      ? ref.watch(transportProvider)
      : ref.watch(realTransportProvider);
  final String? deviceId = source == DebugSource.fake
      ? fakeBridgeDeviceId
      : ref.watch(realDeviceProvider.select((s) => s.deviceId));
  if (deviceId == null) return Stream.value(const LinkStatus());

  BleConnectionState? state;
  BleConnectionInfo? info;
  var closed = false;
  final controller = StreamController<LinkStatus>();

  void emit() {
    if (closed) return;
    controller.add(
      LinkStatus(
        state: state,
        info: state == BleConnectionState.connected ? info : null,
      ),
    );
  }

  Future<void> readInfo() async {
    if (state != BleConnectionState.connected) {
      info = null;
      emit();
      return;
    }
    try {
      info = await transport.connectionInfo(deviceId);
    } catch (_) {
      // The platform does not expose RSSI/MTU on every stack: show "n/a".
      info = null;
    }
    emit();
  }

  final stateSub = transport.connectionState(deviceId).listen((next) {
    state = next;
    if (next == BleConnectionState.connected) {
      readInfo();
    } else {
      info = null;
      emit();
    }
  });
  final poll = Timer.periodic(const Duration(seconds: 2), (_) => readInfo());
  ref.onDispose(() {
    closed = true;
    poll.cancel();
    stateSub.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Per-bridge link figures (MTU, RSSI, rate, loss), refreshed every two
/// seconds while the screen is open.
final bridgeLinksProvider =
    StreamProvider.family<List<BridgeLinkSnapshot>, DebugSource>((ref, source) {
      final service = ref.watch(controllerServiceProvider(source));
      if (service == null) return Stream.value(const []);
      late final StreamController<List<BridgeLinkSnapshot>> controller;
      Timer? poll;
      var closed = false;

      Future<void> read() async {
        if (closed) return;
        final links = await service.bridgeLinks();
        if (!closed) controller.add(links);
      }

      controller = StreamController<List<BridgeLinkSnapshot>>(
        onListen: () {
          unawaited(read());
          poll = Timer.periodic(
            const Duration(seconds: 2),
            (_) => unawaited(read()),
          );
        },
        onCancel: () {
          closed = true;
          poll?.cancel();
        },
      );
      ref.onDispose(() {
        closed = true;
        poll?.cancel();
        controller.close();
      });
      return controller.stream;
    });

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
  final settings = ref.read(stickSettingsProvider);
  final service = ControllerService(
    ref.watch(transportProvider),
    fakeBridgeDeviceId,
    mode: ref.read(streamModeProvider),
    mapping: ref.read(axisMappingProvider),
    filterKind: ref.read(filterKindProvider),
    filterTuning: ref.read(filterTuningProvider),
    stickConfig: settings.config,
    onStickCentre: (hand, centre) => ref
        .read(stickSettingsProvider.notifier)
        .setCentre(hand, centre[0], centre[1]),
  );
  applyStickCentres(service, settings.centres);
  applyFf13Settings(service, ref.read(ff13SettingsProvider));
  ref.onDispose(service.dispose);
  ref.listen(axisMappingProvider, (_, m) => service.setMapping(m));
  ref.listen(filterKindProvider, (_, k) => service.setFilterKind(k));
  ref.listen(
    filterTuningProvider,
    (_, tuning) => service.setFilterTuning(tuning),
  );
  ref.listen(
    stickSettingsProvider.select((s) => s.config),
    (_, c) => service.setStickConfig(c),
  );
  ref.listen(stickSettingsProvider.select((s) => s.centres), (_, centres) {
    applyStickCentres(service, centres);
  });
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
