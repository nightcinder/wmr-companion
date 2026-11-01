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
import 'package:wmr_tracking_android_xr/wmr_tracking_android_xr.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';
import 'package:wmr_tracking_viture/wmr_tracking_viture.dart';
import 'package:wmr_tracking_xreal/wmr_tracking_xreal.dart';

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
      StreamSubscription<void>? protocolSub;
      var closed = false;

      Future<void> read() async {
        if (closed) return;
        final links = await service.bridgeLinks();
        if (!closed) controller.add(links);
      }

      controller = StreamController<List<BridgeLinkSnapshot>>(
        onListen: () {
          unawaited(read());
          // The one-time FF16 read lands after the first poll; refresh then
          // rather than waiting up to two seconds to show the firmware.
          protocolSub = service.protocolChanges.listen(
            (_) => unawaited(read()),
          );
          poll = Timer.periodic(
            const Duration(seconds: 2),
            (_) => unawaited(read()),
          );
        },
        onCancel: () {
          closed = true;
          poll?.cancel();
          protocolSub?.cancel();
        },
      );
      ref.onDispose(() {
        closed = true;
        poll?.cancel();
        protocolSub?.cancel();
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

/// A tracking source the debug screen can attach to the 6DoF viewer.
enum DebugTrackingSource {
  none('None', null),
  simulated('Simulated', null),
  auto('Auto (USB)', null),
  androidXr('Android XR', 'WMR_ANDROID_XR_TRACKING'),
  viture('VITURE', 'WMR_VITURE_TRACKING'),
  xreal('XREAL', 'WMR_XREAL_TRACKING');

  const DebugTrackingSource(this.label, this.buildFlag);

  final String label;

  /// The `--dart-define` that enables this source. Null for [none], [simulated]
  /// and [auto], which gate on the vendor component flags instead.
  final String? buildFlag;
}

/// Picks the vendor source from the native USB/host detection instead of a
/// manual vendor choice.
///
/// The selector only calls the detector when at least one vendor component is
/// built in, so a flag-off build never touches `wmr_tracking_dispatch`.
final debugTrackingSelectorProvider = Provider<TrackingSourceSelector>((ref) {
  return TrackingSourceSelector(
    detector: const PlatformGlassesDetector(),
    flags: TrackingSourceFlags(
      viture: VitureTracking.enabled,
      xreal: XrealTracking.enabled,
      androidXr: AndroidXrTracking.enabled,
    ),
    vitureSource: VitureNeckbandTrackingSource.create,
    xrealSource: XrealAir2UltraTrackingSource.create,
    androidXrSource: AndroidXrTrackingSource.create,
  );
});

/// The source selected in the debug screen. [DebugTrackingSource.none] by
/// default: the viewer shows the controller's 3DoF orientation with an
/// `orientationOnly` badge.
final debugTrackingSourceProvider =
    NotifierProvider<DebugTrackingSourceNotifier, DebugTrackingSelection>(
      DebugTrackingSourceNotifier.new,
    );

/// The selected source and its create/start outcome.
class DebugTrackingSelection {
  const DebugTrackingSelection({
    required this.choice,
    required this.attachment,
  });

  final DebugTrackingSource choice;
  final AsyncValue<DebugTrackingAttachment> attachment;
}

/// Creates the source for [choice], or null when its build flag is off.
typedef DebugTrackingSourceFactory = Future<TrackingSource?> Function(
  DebugTrackingSource choice,
);

/// Swappable in tests, so a source that fails like an unlinked Unity relay can
/// be exercised without a platform channel.
final debugTrackingSourceFactoryProvider = Provider<DebugTrackingSourceFactory>(
  (ref) => createDebugTrackingSource,
);

/// The production factory. Each vendor `create()` returns null without
/// touching its platform channel while its `--dart-define` flag is off.
Future<TrackingSource?> createDebugTrackingSource(
  DebugTrackingSource choice,
) async {
  switch (choice) {
    case DebugTrackingSource.none:
      return null;
    case DebugTrackingSource.auto:
      // Auto detection needs the selector, which the notifier owns; it never
      // reaches this per-vendor factory.
      return null;
    case DebugTrackingSource.simulated:
      return FakeTrackingSource();
    case DebugTrackingSource.androidXr:
      return AndroidXrTrackingSource.create();
    case DebugTrackingSource.viture:
      return VitureNeckbandTrackingSource.create();
    case DebugTrackingSource.xreal:
      return XrealAir2UltraTrackingSource.create();
  }
}

/// The outcome of creating and starting one selected source.
class DebugTrackingAttachment {
  const DebugTrackingAttachment({
    required this.choice,
    this.source,
    this.error,
    this.disabled = false,
    this.message,
  });

  final DebugTrackingSource choice;

  /// The started source, or null when the selection is off, disabled or
  /// failed.
  final TrackingSource? source;

  /// The typed failure from `create()` or `start()`.
  final TrackingException? error;

  /// The source exists but its default-off build flag is not set.
  final bool disabled;

  /// Extra status text, such as the selector's detection result for
  /// [DebugTrackingSource.auto].
  final String? message;

  bool get running => source != null;
}

/// Stops and disposes [source], swallowing teardown failures.
Future<void> releaseDebugTrackingSource(TrackingSource source) async {
  try {
    await source.stop();
  } catch (_) {
    // Teardown is best-effort.
  }
  try {
    await source.dispose();
  } catch (_) {
    // See above.
  }
}

/// Creates and starts the selected source, and detaches the previous one on
/// every change.
///
/// A disabled flag returns [DebugTrackingAttachment.disabled] without touching
/// a platform channel. Every failure is mapped to a [TrackingException], so an
/// unlinked Unity relay or a missing plugin shows a typed status instead of
/// crashing the debug screen.
class DebugTrackingSourceNotifier extends Notifier<DebugTrackingSelection> {
  TrackingSource? _owned;
  int _generation = 0;

  @override
  DebugTrackingSelection build() {
    ref.onDispose(() {
      final source = _owned;
      _owned = null;
      if (source != null) unawaited(releaseDebugTrackingSource(source));
    });
    return const DebugTrackingSelection(
      choice: DebugTrackingSource.none,
      attachment: AsyncValue.data(
        DebugTrackingAttachment(choice: DebugTrackingSource.none),
      ),
    );
  }

  void set(DebugTrackingSource choice) => unawaited(select(choice));

  /// Detaches the current source before creating and starting [choice].
  ///
  /// [choice] is ignored when it arrives after a newer selection; its source,
  /// if it was already created, is released rather than left running.
  Future<void> select(DebugTrackingSource choice) async {
    if (choice == state.choice && !state.attachment.isLoading) return;
    final generation = ++_generation;
    final previous = _owned;
    _owned = null;
    state = DebugTrackingSelection(
      choice: choice,
      attachment: const AsyncValue.loading(),
    );
    if (previous != null) await releaseDebugTrackingSource(previous);
    if (generation != _generation) return;
    if (choice == DebugTrackingSource.none) {
      state = DebugTrackingSelection(
        choice: choice,
        attachment: AsyncValue.data(DebugTrackingAttachment(choice: choice)),
      );
      return;
    }
    if (choice == DebugTrackingSource.auto) {
      final selected = await ref.read(debugTrackingSelectorProvider).select();
      if (generation != _generation) {
        final created = selected.source;
        if (created != null) await releaseDebugTrackingSource(created);
        return;
      }
      if (selected.source != null) _owned = selected.source;
      _publish(
        generation,
        DebugTrackingAttachment(
          choice: choice,
          source: selected.source,
          message: selected.message,
        ),
      );
      return;
    }

    final factory = ref.read(debugTrackingSourceFactoryProvider);
    DebugTrackingAttachment attachment;
    try {
      final created = await factory(choice);
      if (generation != _generation) {
        if (created != null) await releaseDebugTrackingSource(created);
        return;
      }
      if (created == null) {
        attachment = DebugTrackingAttachment(choice: choice, disabled: true);
      } else {
        _owned = created;
        try {
          await created.start();
        } on TrackingException catch (error) {
          if (_owned == created) _owned = null;
          await releaseDebugTrackingSource(created);
          attachment = DebugTrackingAttachment(choice: choice, error: error);
          _publish(generation, attachment);
          return;
        } on Object catch (error) {
          if (_owned == created) _owned = null;
          await releaseDebugTrackingSource(created);
          attachment = DebugTrackingAttachment(
            choice: choice,
            error: TrackingException(
              TrackingExceptionKind.unavailable,
              'Could not start ${choice.label}: $error',
            ),
          );
          _publish(generation, attachment);
          return;
        }
        if (generation != _generation) {
          if (_owned == created) _owned = null;
          await releaseDebugTrackingSource(created);
          return;
        }
        attachment = DebugTrackingAttachment(choice: choice, source: created);
      }
    } on TrackingException catch (error) {
      attachment = DebugTrackingAttachment(choice: choice, error: error);
    } on Object catch (error) {
      attachment = DebugTrackingAttachment(
        choice: choice,
        error: TrackingException(
          TrackingExceptionKind.unavailable,
          'Could not create ${choice.label}: $error',
        ),
      );
    }
    _publish(generation, attachment);
  }

  void _publish(int generation, DebugTrackingAttachment attachment) {
    if (generation != _generation) return;
    state = DebugTrackingSelection(
      choice: attachment.choice,
      attachment: AsyncValue.data(attachment),
    );
  }
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

/// The [SixDofFuser] behind [debugPosesProvider] for [source].
///
/// Hoisted out of the stream provider so "Reset orientation" can drop the
/// offsets learned under the old IMU heading. It is recreated with the tracking
/// source, and with the host clock behind the buffered frames: every
/// `BleTransport` owns its own `MonotonicClock`, while the aligner re-bases the
/// first frames of the new link near its origin. Frames kept from the old
/// domain would sort ahead of every new one, so no controller sample would find
/// a frame and the viewer would stay `orientationOnly` until the two clocks
/// met.
final debugFuserProvider = Provider.family<SixDofFuser?, DebugSource>((
  ref,
  source,
) {
  if (source == DebugSource.fake) {
    ref.watch(transportProvider);
  } else {
    ref.watch(realLinkTransportProvider);
  }
  final tracking = ref
      .watch(debugTrackingSourceProvider)
      .attachment
      .value
      ?.source;
  return tracking == null ? null : SixDofFuser();
});

/// Poses for the 6DoF viewer.
///
/// A loaded recording wins over the live stream and is stepped by
/// [poseReplayProvider]. Otherwise decoded FF12/FF14 samples feed
/// [SixDofFuser] at the controller rate. With no tracking frames the fuser
/// returns an `orientationOnly` pose. [debugTrackingSourceProvider] picks the
/// source: [DebugTrackingSource.simulated] emits a deterministic
/// [FakeTrackingSource] trajectory, while Android XR, VITURE and XREAL are
/// created and started by [DebugTrackingSourceNotifier]. Raw mode has no IMU
/// data, so the fake bridge keeps its synthetic orientation there.
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
  final selection = ref.watch(debugTrackingSourceProvider);
  final choice = selection.choice;
  final tracking = selection.attachment.value?.source;
  final simulated = choice == DebugTrackingSource.simulated;
  final fuser = ref.watch(debugFuserProvider(source));
  const motion = SyntheticMotion();
  final clock = Stopwatch()..start();
  final transport = source == DebugSource.fake
      ? ref.watch(transportProvider)
      : ref.watch(realLinkTransportProvider);
  final hostClock = service?.transport.clock ?? transport.clock;
  final aligner = SourceClockAligner();
  StreamSubscription<TrackingFrame>? trackingSub;
  Pose? head;
  TrackingFrame? lastTracking;

  if (tracking != null) {
    trackingSub = tracking.frames.listen(
      (frame) {
        // The simulated trajectory already carries this provider's clock.
        final aligned = simulated
            ? frame
            : frame.withHostTime(
                aligner.align(
                  sourceTimeNs: frame.timeNs,
                  hostTimeNs: hostClock.nowUs * 1000,
                ),
              );
        fuser?.onTrackingFrame(aligned);
        lastTracking = aligned;
        head = aligned.head?.pose;
      },
      onError: (Object _, StackTrace _) {
        // The attachment status shows source failures; the viewer keeps the
        // orientation-only fallback.
      },
    );
  }

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
    // Frames are aligned to the transport's monotonic clock and controller
    // samples already live in it, so poses tick on that same clock. The
    // synthetic motion phase above keeps its own tick clock.
    final nowNs = hostClock.nowUs * 1000 + 1;
    final trackingSource = tracking;
    final fuserState = fuser;
    if (simulated && trackingSource != null && fuserState != null) {
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
      if (trackingSource is FakeTrackingSource) {
        trackingSource.addFrame(frame);
      }
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
