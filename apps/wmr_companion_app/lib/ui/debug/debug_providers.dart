import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/orientation.dart';
import 'package:wmr_core/domain/synthetic_motion.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import '../connect/connect_providers.dart';
import 'pose_replay.dart';
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
      : ref.watch(realLinkTransportProvider);
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

/// Whether the debug viewer simulates a 6DoF tracking source.
///
/// Off by default: the normal build shows the controller's 3DoF orientation
/// with an `orientationOnly` badge. Turning it on feeds a deterministic
/// [FakeTrackingSource] trajectory through [SixDofFuser] so the viewer can be
/// exercised without a headset.
final simulatedSixDofProvider = NotifierProvider<SimulatedSixDof, bool>(
  SimulatedSixDof.new,
);

class SimulatedSixDof extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// One viewer update: the fused pose per hand plus the head that produced it.
class DebugPoses {
  const DebugPoses({
    this.left,
    this.right,
    this.head,
    this.tracking,
    this.replayed = false,
  });

  final ControllerPose? left;
  final ControllerPose? right;
  final Pose? head;

  /// The tracking frame delivered with this tick, if any. Recorded alongside
  /// the controller poses so a capture keeps its 6DoF anchors.
  final TrackingFrame? tracking;

  /// Whether these poses came from a recorded file rather than the live
  /// controller and tracking sources.
  final bool replayed;

  ControllerPose? forHand(int hand) => hand == 0 ? left : right;
}

/// Poses for the 6DoF viewer.
///
/// A loaded recording wins over the live stream and is stepped by
/// [poseReplayProvider]. Otherwise decoded FF12/FF14 samples feed
/// [SixDofFuser] at the controller rate. With no tracking frames the fuser
/// returns an `orientationOnly` pose; with [simulatedSixDofProvider] on, a
/// [FakeTrackingSource] emits a deterministic hand trajectory that lifts it to
/// `handAnchor`. Raw mode has no IMU data, so the fake bridge keeps its
/// synthetic orientation there.
final debugPosesProvider = StreamProvider.family<DebugPoses, DebugSource>((
  ref,
  source,
) {
  final replay = ref.watch(poseReplayProvider);
  final replaySample = replay.sample;
  if (replay.active) {
    return Stream.value(
      DebugPoses(
        left: replaySample?.left,
        right: replaySample?.right,
        head: replaySample?.tracking?.head?.pose,
        tracking: replaySample?.tracking,
        replayed: true,
      ),
    );
  }
  final mode = ref.watch(streamModeProvider);
  final decoded = mode.carriesRecords;
  final service = decoded ? ref.watch(controllerServiceProvider(source)) : null;
  final simulated = ref.watch(simulatedSixDofProvider);
  final fuser = simulated ? SixDofFuser() : null;
  final tracking = simulated ? FakeTrackingSource() : null;
  const motion = SyntheticMotion();
  final clock = Stopwatch()..start();
  var trackingStarted = false;
  StreamSubscription<TrackingFrame>? trackingSub;
  Pose? head;
  TrackingFrame? lastTracking;

  Future<void> startTracking() async {
    final source = tracking;
    final fuserState = fuser;
    if (source == null || trackingStarted) return;
    // Subscribe before start so no frame is lost between the two.
    trackingSub = source.frames.listen(fuserState?.onTrackingFrame);
    try {
      await source.start();
      trackingStarted = true;
    } catch (_) {
      // Leave the viewer on the orientation-only fallback.
    }
  }

  if (tracking != null) unawaited(startTracking());

  late final StreamController<DebugPoses> controller;
  Timer? timer;

  Quaternion orientationFor(int hand, Duration now) {
    if (service != null && decoded) {
      return service.pipeline(hand).orientation;
    }
    return source == DebugSource.fake ? motion.at(now) : Quaternion.identity();
  }

  void tick() {
    if (controller.isClosed) return;
    final now = clock.elapsed;
    final nowNs = now.inMicroseconds * 1000 + 1;
    final trackingSource = tracking;
    final fuserState = fuser;
    if (trackingSource != null && fuserState != null && trackingStarted) {
      final phase = now.inMilliseconds / 1000.0;
      final headPose = Pose(
        translation: Vector3(0, 1.6, 0),
        rotation: Quaternion.identity(),
      );
      final sway = math.sin(phase * 1.2);
      final lift = math.cos(phase * 2.0);
      final frame = TrackingFrame(
        timeNs: nowNs,
        hostTimeNs: nowNs,
        head: TrackedPose(pose: headPose),
        leftHand: HandPose(
          hand: TrackedHand.left,
          palm: TrackedPose(
            pose: Pose(
              translation: Vector3(
                -0.18 + sway * 0.12,
                -0.25 + lift * 0.06,
                -0.35 + sway * 0.10,
              ),
              rotation: Quaternion.identity(),
            ),
          ),
        ),
        rightHand: HandPose(
          hand: TrackedHand.right,
          palm: TrackedPose(
            pose: Pose(
              translation: Vector3(
                0.18 - sway * 0.12,
                -0.25 - lift * 0.06,
                -0.35 - sway * 0.10,
              ),
              rotation: Quaternion.identity(),
            ),
          ),
        ),
      );
      trackingSource.addFrame(frame);
      lastTracking = frame;
      head = headPose;
    }

    ControllerPose poseFor(int hand) {
      final orientation = orientationFor(hand, now);
      if (fuserState != null) {
        return fuserState.update(
          hand: hand == 0 ? TrackedHand.left : TrackedHand.right,
          orientation: orientation,
          hostTimeNs: nowNs,
        );
      }
      return ControllerPose(
        hand: hand == 0 ? TrackedHand.left : TrackedHand.right,
        hostTimeNs: nowNs,
        orientation: orientation,
      );
    }

    controller.add(
      DebugPoses(
        left: poseFor(0),
        right: poseFor(1),
        head: head,
        tracking: lastTracking,
      ),
    );
  }

  controller = StreamController<DebugPoses>(
    onListen: () {
      tick();
      timer = Timer.periodic(const Duration(milliseconds: 33), (_) => tick());
    },
    onCancel: () => timer?.cancel(),
  );
  ref.onDispose(() {
    timer?.cancel();
    unawaited(trackingSub?.cancel() ?? Future<void>.value());
    unawaited(controller.close());
    final source = tracking;
    if (source != null) {
      unawaited(() async {
        try {
          await source.stop();
        } catch (_) {
          // Teardown is best-effort.
        }
        try {
          await source.dispose();
        } catch (_) {
          // Teardown is best-effort.
        }
      }());
    }
  });
  return controller.stream;
});

/// Yaw removed from the displayed orientation ("reset orientation") in the
/// synthetic view. The fused view resets the filter's heading instead.
final yawOffsetProvider = NotifierProvider<YawOffset, double>(YawOffset.new);

class YawOffset extends Notifier<double> {
  @override
  double build() => 0;

  void zeroAt(Quaternion raw) => state = eulerFromQuaternion(raw).yaw;
}
