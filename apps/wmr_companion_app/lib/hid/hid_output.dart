import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/services/controller_service.dart';

import '../ui/connect/connect_providers.dart';
import '../ui/debug/debug_providers.dart';
import '../ui/gamepad/gamepad_providers.dart';

import 'package:wmr_companion_hid_android/wmr_companion_hid_android.dart';

final hidTransportProvider = Provider<HidGamepadTransport>(
  (ref) => MethodChannelHidGamepad(),
);

class HidOutputState {
  const HidOutputState({
    this.status = const HidStatus(HidState.idle),
    this.hosts = const [],
    this.running = false,
    this.reportsSent = 0,
    this.sendErrors = 0,
  });

  final HidStatus status;

  /// Bonded devices, from the last refresh.
  final List<HidHost> hosts;

  /// Whether the mapped state is being forwarded to the transport.
  final bool running;
  final int reportsSent;
  final int sendErrors;

  HidOutputState copyWith({
    HidStatus? status,
    List<HidHost>? hosts,
    bool? running,
    int? reportsSent,
    int? sendErrors,
  }) => HidOutputState(
    status: status ?? this.status,
    hosts: hosts ?? this.hosts,
    running: running ?? this.running,
    reportsSent: reportsSent ?? this.reportsSent,
    sendErrors: sendErrors ?? this.sendErrors,
  );
}

/// Forwards the mapped gamepad state to the Bluetooth HID transport.
///
/// Subscribes to the service's decoded samples directly (not to the 30 Hz
/// screen provider), maps both hands with the live [GamepadConfig] and sends
/// a report when the encoded bytes change. Only while the app is open and
/// started here; nothing runs in the background.
///
/// A bridge reconnect replaces the [ControllerService] object. The forwarder
/// re-points at the new one by itself, so a drop does not need a manual Stop
/// and Start. With several bridges, losing one releases the hand it fed
/// (neutral sticks, triggers and buttons) and keeps forwarding the other;
/// the returning bridge is picked up again on its first sample. The
/// [start] and [stop] methods remain the user-facing on/off switch.
class HidOutput extends Notifier<HidOutputState> {
  StreamSubscription<HidStatus>? _statusSub;
  StreamSubscription<DecodedSample>? _sampleSub;
  StreamSubscription<String>? _removalSub;
  ProviderSubscription<ControllerService?>? _serviceSub;
  ProviderSubscription<RealDeviceState>? _deviceSub;
  ControllerService? _service;
  int _bindGeneration = 0;
  final List<HandInput?> _latest = [null, null];

  /// Which bridge last fed each hand, so a bridge loss can release exactly
  /// that hand.
  final Map<int, String> _handBridge = {};
  Uint8List? _lastSent;
  GamepadState? _previous;

  @override
  HidOutputState build() {
    final transport = ref.watch(hidTransportProvider);
    _statusSub = transport.status.listen(_onStatus);
    ref.onDispose(() {
      _statusSub?.cancel();
      _sampleSub?.cancel();
      _removalSub?.cancel();
      _serviceSub?.close();
      _deviceSub?.close();
    });
    // A threshold change takes effect without waiting for the next sample.
    ref.listen(gamepadConfigProvider, (_, _) => _push());
    return const HidOutputState();
  }

  HidGamepadTransport get _transport => ref.read(hidTransportProvider);

  void _onStatus(HidStatus s) {
    final becameConnected =
        s.state == HidState.connected &&
        state.status.state != HidState.connected;
    state = state.copyWith(status: s);
    if (becameConnected) {
      // A new host has seen no report yet.
      _lastSent = null;
      _push();
    }
  }

  /// Registers the gamepad and starts forwarding samples of [source].
  Future<void> start(DebugSource source) async {
    _serviceSub?.close();
    _serviceSub = ref.listen(
      controllerServiceProvider(source),
      (_, next) => unawaited(_bindService(next)),
    );
    _deviceSub?.close();
    _deviceSub = source == DebugSource.real
        ? ref.listen(realDeviceProvider, _onRealDeviceState)
        : null;

    state = state.copyWith(running: true);
    await _transport.start();
    await _bindService(ref.read(controllerServiceProvider(source)));
    await refreshHosts();
  }

  Future<void> stop() async {
    _serviceSub?.close();
    _serviceSub = null;
    _deviceSub?.close();
    _deviceSub = null;
    _bindGeneration++;
    await _sampleSub?.cancel();
    _sampleSub = null;
    await _removalSub?.cancel();
    _removalSub = null;
    _service = null;
    _clearHands();
    _lastSent = null;
    state = state.copyWith(running: false);
    await _transport.stop();
  }

  /// An explicit bridge disconnect is not a drop: stop rather than wait for
  /// samples the user asked not to receive.
  void _onRealDeviceState(RealDeviceState? previous, RealDeviceState next) {
    final disconnectedOnPurpose =
        (previous?.disconnectEpoch ?? 0) != next.disconnectEpoch;
    if (disconnectedOnPurpose && !next.connected && state.running) {
      unawaited(stop());
    }
  }

  /// Re-points the forwarding at [service]. Called once on start and again
  /// whenever the provider swaps the service object under a reconnect.
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
    _lastSent = null;
    if (service != null) {
      _sampleSub = service.decodedSamples.listen((s) {
        final hand = s.record.hand;
        _latest[hand] = HandInput.fromSample(s);
        _handBridge[hand] = s.bridgeId;
        _push();
      });
      _removalSub = service.deviceRemovals.listen(_onDeviceRemoved);
    }
    // A host that is still connected should see the pad go neutral while no
    // stream feeds it, not the last sample before the drop.
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
      _handBridge.remove(hand);
    }
    // Judge trigger edges from scratch: the missing hand is released.
    _previous = null;
    _push();
  }

  void _clearHands() {
    _latest[0] = _latest[1] = null;
    _handBridge.clear();
    _previous = null;
  }

  Future<void> refreshHosts() async {
    try {
      state = state.copyWith(hosts: await _transport.bondedHosts());
    } catch (_) {
      // Permission missing or no plugin: the status already says so.
    }
  }

  Future<void> connect(String address) => _transport.connect(address);

  Future<void> disconnect() => _transport.disconnect();

  Future<void> requestDiscoverable() => _transport.requestDiscoverable();

  void _push() {
    if (!state.running || state.status.state != HidState.connected) return;
    final mapped = mapGamepad(
      _latest[0],
      _latest[1],
      ref.read(gamepadConfigProvider),
      previous: _previous,
    );
    _previous = mapped;
    final report = encodeHidReport(mapped);
    final last = _lastSent;
    if (last != null && _same(last, report)) return;
    _lastSent = report;
    _send(report);
  }

  Future<void> _send(Uint8List report) async {
    // One in flight at a time would drop reports; the platform channel
    // preserves order, so just fire and count failures.
    try {
      await _transport.sendReport(report);
      state = state.copyWith(reportsSent: state.reportsSent + 1);
    } catch (_) {
      _lastSent = null;
      state = state.copyWith(sendErrors: state.sendErrors + 1);
    }
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final hidOutputProvider = NotifierProvider<HidOutput, HidOutputState>(
  HidOutput.new,
);
