import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_companion/wmr_companion.dart';

import '../../ble/universal_ble_adapter.dart';
import '../../ble/universal_ble_transport.dart';

import 'package:wmr_core/services/controller_service.dart';

import '../debug/stream_settings.dart';

/// The real BLE transport. Created on first use, so the fake-bridge path
/// never touches the Bluetooth plugin. Tests override it with a transport on
/// a fake adapter.
final realTransportProvider = Provider<UniversalBleTransport>((ref) {
  final transport = UniversalBleTransport(adapter: UniversalBleAdapter());
  ref.onDispose(transport.dispose);
  return transport;
});

class RealDeviceState {
  const RealDeviceState({
    this.status = const BleLinkStatus(BleLinkPhase.idle),
    this.results = const [],
    this.deviceId,
    this.stats,
    this.mode,
  });

  final BleLinkStatus status;

  /// Requested stream and its fault, from the service. Null before connect.
  final ModeState? mode;

  /// Latest sighting per device, strongest signal first.
  final List<BleScanResult> results;

  /// The device we connected to (or lost).
  final String? deviceId;
  final StreamStats? stats;

  bool get scanning => status.phase == BleLinkPhase.scanning;
  bool get connected => status.phase == BleLinkPhase.ready;
  bool get busy => const {
    BleLinkPhase.connecting,
    BleLinkPhase.negotiatingMtu,
    BleLinkPhase.discovering,
    BleLinkPhase.subscribing,
    BleLinkPhase.disconnecting,
  }.contains(status.phase);
}

final realDeviceProvider =
    NotifierProvider<RealDeviceController, RealDeviceState>(
      RealDeviceController.new,
    );

/// Drives scan, connect and the [WmrCompanion] session for the real bridge.
///
/// The facade owns the pipeline; this controller adapts its connection
/// lifecycle to the screen's existing [RealDeviceState] and keeps the raw
/// [ControllerService] reachable for the diagnostic screens until phase 4.
class RealDeviceController extends Notifier<RealDeviceState> {
  final Map<String, BleScanResult> _seen = {};
  StreamSubscription<BleScanResult>? _scanSub;
  StreamSubscription<BleLinkStatus>? _statusSub;
  WmrCompanion? _companion;
  Timer? _statsTimer;

  @override
  RealDeviceState build() {
    final transport = ref.watch(realTransportProvider);
    _statusSub = transport.statusChanges.listen((s) {
      state = RealDeviceState(
        status: s,
        results: state.results,
        deviceId: state.deviceId,
        stats: state.stats,
        mode: state.mode,
      );
    });
    ref.listen(axisMappingProvider, (_, m) => _companion?.setAxisMapping(m));
    ref.listen(filterKindProvider, (_, _) => _applyFusion());
    ref.listen(filterTuningProvider, (_, _) => _applyFusion());
    ref.listen(
      stickSettingsProvider.select((s) => s.config),
      (_, c) => _companion?.setStickConfig(c),
    );
    ref.listen(stickSettingsProvider.select((s) => s.centres), (_, centres) {
      final service = this.service;
      if (service != null) applyStickCentres(service, centres);
    });
    ref.listen(ff13SettingsProvider, (_, s) {
      final service = this.service;
      if (service != null) applyFf13Settings(service, s);
    });
    ref.onDispose(() {
      _scanSub?.cancel();
      _statusSub?.cancel();
      _statsTimer?.cancel();
      final companion = _companion;
      _companion = null;
      if (companion != null) unawaited(companion.dispose());
    });
    return RealDeviceState(status: transport.status);
  }

  UniversalBleTransport get _transport => ref.read(realTransportProvider);

  /// The service behind the current connection, for consumers that share its
  /// frame stream (the capture screen). Null before the first connect.
  ControllerService? get service => _companion?.debugControllerService;

  void _applyFusion() {
    _companion?.setFusion(
      FusionConfig(
        kind: ref.read(filterKindProvider),
        tuning: ref.read(filterTuningProvider),
      ),
    );
  }

  void _update({List<BleScanResult>? results, String? deviceId}) {
    state = RealDeviceState(
      status: _transport.status,
      results: results ?? state.results,
      deviceId: deviceId ?? state.deviceId,
      stats: state.stats,
      mode: state.mode,
    );
  }

  /// Failures arrive on the transport's status stream as well, so errors
  /// here only need to be swallowed.
  Future<void> startScan() async {
    await _scanSub?.cancel();
    _seen.clear();
    _update(results: const []);
    _scanSub = _transport.scan().listen((r) {
      _seen[r.deviceId] = r;
      _update(
        results: _seen.values.toList()
          ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999)),
      );
    }, onError: (Object _) {});
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _transport.stopScan();
    _update();
  }

  /// Connects and subscribes. Also the way to reconnect after a lost
  /// connection: it repeats the whole sequence.
  ///
  /// The facade owns the pipeline and its lifecycle; this method only feeds it
  /// the app's current settings and publishes the service counters the screen
  /// already shows.
  Future<void> connect(String deviceId) async {
    await stopScan();
    _update(deviceId: deviceId);
    final previous = _companion;
    _companion = null;
    await previous?.dispose();

    final settings = ref.read(stickSettingsProvider);
    final companion = _companion = WmrCompanion(
      ble: _transport,
      config: WmrCompanionConfig(
        streamMode: ref.read(streamModeProvider),
        fusion: FusionConfig(
          kind: ref.read(filterKindProvider),
          tuning: ref.read(filterTuningProvider),
        ),
        axisMapping: ref.read(axisMappingProvider),
        sticks: settings.config,
      ),
      onStickCentre: (hand, centre) => ref
          .read(stickSettingsProvider.notifier)
          .setCentre(hand.wireIndex, centre[0], centre[1]),
    );
    for (var h = 0; h < settings.centres.length; h++) {
      final centre = settings.centres[h];
      if (centre == null) {
        companion.clearStickCentre(Hand.of(h));
      } else {
        companion.setStickCentre(Hand.of(h), centre[0], centre[1]);
      }
    }
    final ff13 = ref.read(ff13SettingsProvider);
    for (var h = 0; h < ff13.calibrations.length; h++) {
      companion.setFf13Calibration(
        Hand.of(h),
        ff13.calibrations[h],
        apply: ff13.apply[h],
      );
    }

    try {
      await companion.connect(WmrBridgeDevice(id: deviceId));
    } on WmrStreamModeException {
      // The link is up but the stream did not enable; the banner reads the
      // fault from the service. Keep the session for the retry.
    } on WmrException {
      return; // connection failure is already in the transport status
    }
    final service = companion.debugControllerService;
    if (service == null) return;

    void publish() {
      // Read the service through the getter on every tick: the facade creates
      // a new ControllerService when it reconnects after a drop.
      final current = this.service;
      if (current == null) return;
      state = RealDeviceState(
        status: _transport.status,
        results: state.results,
        deviceId: state.deviceId,
        stats: current.stats,
        mode: current.modeState,
      );
    }

    publish();
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => publish(),
    );
  }

  /// Switches between the FF11, FF12 and FF14 streams (CCC order is
  /// the transport's job). The choice is remembered for the next connect.
  /// A refusal shows up in [RealDeviceState.mode], never silently.
  Future<void> setStreamMode(StreamMode mode) async {
    ref.read(streamModeProvider.notifier).set(mode);
    final companion = _companion;
    final service = companion?.debugControllerService;
    if (companion == null || service == null) return;
    try {
      await companion.setStreamMode(mode);
    } on WmrException {
      // Typed failure; the mode state below carries the fault for the banner.
    }
    state = RealDeviceState(
      status: _transport.status,
      results: state.results,
      deviceId: state.deviceId,
      stats: service.stats,
      mode: service.modeState,
    );
  }

  Future<void> disconnect() async {
    final id = state.deviceId;
    _statsTimer?.cancel();
    final companion = _companion;
    _companion = null;
    if (companion != null) {
      // The facade owns the link, so it also performs the intentional
      // disconnect that suppresses the auto-reconnect path.
      await companion.disconnect();
      await companion.dispose();
      return;
    }
    if (id != null) await _transport.disconnect(id);
  }
}
