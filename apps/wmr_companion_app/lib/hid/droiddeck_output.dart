import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import 'package:wmr_core/domain/droiddeck_xr_sink.dart';
import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/droiddeck_xr_transport.dart';

import '../ui/connect/connect_providers.dart';
import '../ui/debug/debug_providers.dart';
import '../ui/gamepad/gamepad_providers.dart';
import 'hid_output.dart';

/// Opens the DroidDeck v0 socket. A seam for tests and for a host that reaches
/// the sink another way.
final droidDeckTransportFactoryProvider =
    Provider<Future<DroidDeckXrTransport> Function()>(
      (ref) => openDroidDeckXrTransport,
    );

/// The Android `InputDevice` the sink asks DroidDeck to ignore.
///
/// The companion sends no claim: the flat gamepad it would replace is its own
/// Bluetooth HID role, which [DroidDeckHidPeripheral] turns off for the whole
/// session. Suppressing a bridge that Android binds as an `InputDevice` needs
/// that device's vendor/product id, which the app cannot read without a new
/// platform call; see `docs/GAMEPAD.md`.
final droidDeckClaimProvider = Provider<DroidDeckXrClaim?>((ref) => null);

/// Where the DroidDeck session is. The `v0` host owns the recenter counter, so
/// the companion never sets it.
enum DroidDeckStatus {
  /// No socket and no session.
  idle,

  /// Opening the socket, disabling the HID role and sending the claim.
  connecting,

  /// Packets are on the wire.
  streaming,

  /// The last start or send failed; see [DroidDeckOutputState.message].
  error,
}

class DroidDeckOutputState {
  const DroidDeckOutputState({
    this.status = DroidDeckStatus.idle,
    this.message,
    this.packetsSent = 0,
    this.sendErrors = 0,
    this.leftPosition = false,
    this.rightPosition = false,
  });

  final DroidDeckStatus status;

  /// Why the session stopped or failed to start.
  final String? message;
  final int packetsSent;
  final int sendErrors;

  /// Whether the last packet carried a tracked position for that hand. False
  /// means the host gets a rotation-only pose for it.
  final bool leftPosition;
  final bool rightPosition;

  bool get running =>
      status == DroidDeckStatus.connecting ||
      status == DroidDeckStatus.streaming;

  DroidDeckOutputState copyWith({
    DroidDeckStatus? status,
    String? message,
    int? packetsSent,
    int? sendErrors,
    bool? leftPosition,
    bool? rightPosition,
  }) => DroidDeckOutputState(
    status: status ?? this.status,
    message: message,
    packetsSent: packetsSent ?? this.packetsSent,
    sendErrors: sendErrors ?? this.sendErrors,
    leftPosition: leftPosition ?? this.leftPosition,
    rightPosition: rightPosition ?? this.rightPosition,
  );
}

/// Turns the phone's Bluetooth HID peripheral role off for a DroidDeck session
/// and back on when it ends.
///
/// Android's Bluetooth HID peripheral mode disrupts the local Bluetooth host
/// connection DroidDeck needs, so the flat gamepad has to go away first. Only
/// a role this class turned off is restored: a session started while the
/// gamepad was already off leaves it off.
class DroidDeckHidPeripheral implements DroidDeckXrHidPeripheral {
  DroidDeckHidPeripheral(this._ref, this._source);

  final Ref _ref;
  final DebugSource _source;
  bool _wasRunning = false;

  @override
  Future<void> disable() async {
    _wasRunning = _ref.read(hidOutputProvider).running;
    if (_wasRunning) await _ref.read(hidOutputProvider.notifier).stop();
  }

  @override
  Future<void> restore() async {
    final wasRunning = _wasRunning;
    _wasRunning = false;
    if (!wasRunning || !_ref.mounted) return;
    // The user turned the flat gamepad back on during the session; leave it.
    if (_ref.read(hidOutputProvider).running) return;
    await _ref.read(hidOutputProvider.notifier).start(_source);
  }
}

/// Streams the mapped controllers to DroidDeck as `v0` external 6DoF input.
///
/// Subscribes to the service's decoded samples directly, like [HidOutput], so
/// every controller sample becomes a packet: the host republishes a controller
/// only while packets keep arriving. Orientation is the pipeline's; position
/// comes from the live 6DoF poses when a tracking source is attached, and both
/// hands are sent rotation-only otherwise.
///
/// [start] also turns the Bluetooth HID gamepad off and [stop] turns it back
/// on, because Android's HID peripheral mode breaks the local Bluetooth host
/// link the stream needs. Nothing runs in the background.
class DroidDeckOutput extends Notifier<DroidDeckOutputState> {
  DroidDeckXrSink? _sink;
  StreamSubscription<DecodedSample>? _sampleSub;
  ProviderSubscription<AsyncValue<DebugPoses>>? _poseSub;
  StreamSubscription<String>? _removalSub;
  ProviderSubscription<ControllerService?>? _serviceSub;
  ProviderSubscription<RealDeviceState>? _deviceSub;
  ControllerService? _service;
  int _generation = 0;
  int _bindGeneration = 0;
  final List<DecodedSample?> _latest = [null, null];
  final List<Vector3?> _position = [null, null];
  final Map<int, String> _handBridge = {};
  GamepadState? _previous;

  @override
  DroidDeckOutputState build() {
    // Starting the flat gamepad again would break the link this stream needs,
    // so the stream gives way to it.
    ref.listen(hidOutputProvider, _onHidOutput);
    ref.onDispose(() => unawaited(_teardown()));
    return const DroidDeckOutputState();
  }

  /// Opens the socket and streams [source] until [stop].
  Future<void> start(DebugSource source) async {
    if (state.running) return;
    final generation = ++_generation;
    state = state.copyWith(status: DroidDeckStatus.connecting, message: null);
    DroidDeckXrTransport? transport;
    try {
      transport = await ref.read(droidDeckTransportFactoryProvider)();
      if (generation != _generation) {
        await transport.close();
        return;
      }
      final sink = DroidDeckXrSink(
        transport: transport,
        claim: ref.read(droidDeckClaimProvider),
        hidPeripheral: DroidDeckHidPeripheral(ref, source),
      );
      await sink.start();
      if (generation != _generation) {
        await sink.stop();
        return;
      }
      _sink = sink;
      await _bindSource(source);
      if (generation != _generation) return;
      state = state.copyWith(status: DroidDeckStatus.streaming, message: null);
    } on Object catch (error) {
      await transport?.close();
      if (generation != _generation) return;
      state = DroidDeckOutputState(
        status: DroidDeckStatus.error,
        message: _describe(error),
      );
    }
  }

  /// Ends the session and puts the Bluetooth HID role back where it was.
  Future<void> stop() async {
    final sink = _sink;
    if (sink == null && !state.running) return;
    _generation++;
    _unbindSource();
    _sink = null;
    _clearHands();
    state = const DroidDeckOutputState();
    await sink?.stop();
  }

  void _onHidOutput(HidOutputState? previous, HidOutputState next) {
    if (!next.running || !state.running) return;
    unawaited(
      stop().then((_) {
        if (ref.mounted) {
          state = const DroidDeckOutputState(
            message: 'Stopped: Bluetooth HID output was started.',
          );
        }
      }),
    );
  }

  Future<void> _bindSource(DebugSource source) async {
    _unbindSource();
    _serviceSub = ref.listen(
      controllerServiceProvider(source),
      (_, next) => unawaited(_bindService(next)),
    );
    _deviceSub = source == DebugSource.real
        ? ref.listen(realDeviceProvider, _onRealDeviceState)
        : null;
    // Positions come from the same fuser the 6DoF viewer uses, so the stream
    // matches what the debug screen shows.
    _poseSub = ref.listen(debugPosesProvider(source), (_, next) {
      final poses = next.value;
      if (poses == null || poses.replayed) return;
      _position[0] = poses.left?.position;
      _position[1] = poses.right?.position;
    });
    await _bindService(ref.read(controllerServiceProvider(source)));
  }

  void _unbindSource() {
    _serviceSub?.close();
    _serviceSub = null;
    _deviceSub?.close();
    _deviceSub = null;
    _poseSub?.close();
    _poseSub = null;
    _bindGeneration++;
    unawaited(_sampleSub?.cancel());
    _sampleSub = null;
    unawaited(_removalSub?.cancel());
    _removalSub = null;
    _service = null;
  }

  /// An explicit bridge disconnect is not a drop: end the session rather than
  /// wait for samples the user asked not to receive.
  void _onRealDeviceState(RealDeviceState? previous, RealDeviceState next) {
    final disconnectedOnPurpose =
        (previous?.disconnectEpoch ?? 0) != next.disconnectEpoch;
    if (disconnectedOnPurpose && !next.connected && state.running) {
      unawaited(stop());
    }
  }

  /// Re-points the stream at [service]. Called once on start and again
  /// whenever a reconnect swaps the service object.
  Future<void> _bindService(ControllerService? service) async {
    if (service == _service) return;
    _service = service;
    final generation = ++_bindGeneration;
    await _sampleSub?.cancel();
    await _removalSub?.cancel();
    if (generation != _bindGeneration) return;
    _sampleSub = null;
    _removalSub = null;
    _clearHands();
    if (service != null) {
      _sampleSub = service.decodedSamples.listen((s) {
        final hand = s.record.hand;
        _latest[hand] = s;
        _handBridge[hand] = s.bridgeId;
        _push();
      });
      _removalSub = service.deviceRemovals.listen(_onDeviceRemoved);
    }
    _push();
  }

  void _onDeviceRemoved(String bridgeId) {
    final hands = [
      for (final e in _handBridge.entries)
        if (e.value == bridgeId) e.key,
    ];
    if (hands.isEmpty) return;
    for (final hand in hands) {
      _latest[hand] = null;
      _position[hand] = null;
      _handBridge.remove(hand);
    }
    // Only the removed hand's trigger edge is reset; the surviving hand keeps
    // its L2/R2 hysteresis (see [HidOutput]).
    final previous = _previous;
    if (previous != null) {
      final buttons = {...previous.buttons};
      for (final hand in hands) {
        buttons.remove(hand == 0 ? GamepadButton.l2 : GamepadButton.r2);
      }
      _previous = GamepadState(
        buttons: buttons,
        leftStick: previous.leftStick,
        rightStick: previous.rightStick,
        leftTrigger: previous.leftTrigger,
        rightTrigger: previous.rightTrigger,
        leftConnected: previous.leftConnected,
        rightConnected: previous.rightConnected,
      );
    }
    _push();
  }

  void _clearHands() {
    _latest[0] = _latest[1] = null;
    _position[0] = _position[1] = null;
    _handBridge.clear();
    _previous = null;
  }

  /// Sends the latest sample of both hands, with a null hand disconnected.
  void _push() {
    final sink = _sink;
    if (sink == null || state.status != DroidDeckStatus.streaming) return;
    final mapped = mapGamepad(
      _latest[0] == null ? null : HandInput.fromSample(_latest[0]!),
      _latest[1] == null ? null : HandInput.fromSample(_latest[1]!),
      ref.read(gamepadConfigProvider),
      previous: _previous,
    );
    _previous = mapped;
    unawaited(_submit(sink, mapped));
  }

  Future<void> _submit(DroidDeckXrSink sink, GamepadState mapped) async {
    final left = _triple(_position[0]);
    final right = _triple(_position[1]);
    try {
      await sink.submit(
        left: _latest[0],
        right: _latest[1],
        gamepad: mapped,
        leftPosition: left ?? const [0, 0, 0],
        rightPosition: right ?? const [0, 0, 0],
      );
      if (!identical(sink, _sink)) return;
      state = state.copyWith(
        packetsSent: state.packetsSent + 1,
        leftPosition: left != null,
        rightPosition: right != null,
      );
    } on Object catch (error) {
      if (!identical(sink, _sink)) return;
      final message = _describe(error);
      final sent = state.packetsSent;
      final errors = state.sendErrors + 1;
      final leftPose = state.leftPosition;
      final rightPose = state.rightPosition;
      await stop();
      // stop() resets the state; keep the failure and the counters visible.
      if (!ref.mounted) return;
      state = DroidDeckOutputState(
        status: DroidDeckStatus.error,
        message: message,
        packetsSent: sent,
        sendErrors: errors,
        leftPosition: leftPose,
        rightPosition: rightPose,
      );
    }
  }

  Future<void> _teardown() async {
    _generation++;
    _unbindSource();
    final sink = _sink;
    _sink = null;
    await sink?.stop();
  }

  static List<double>? _triple(Vector3? v) =>
      v == null ? null : [v.x, v.y, v.z];

  static String _describe(Object error) => switch (error) {
    DroidDeckXrTransportException(:final message) => message,
    _ => '$error',
  };
}

final droidDeckOutputProvider =
    NotifierProvider<DroidDeckOutput, DroidDeckOutputState>(
      DroidDeckOutput.new,
    );
