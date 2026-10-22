import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/ble_transport.dart';
import '../../ble/universal_ble_adapter.dart';
import '../../ble/universal_ble_transport.dart';
import '../../services/controller_service.dart';
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

/// Drives scan, connect and the [ControllerService] for the real bridge.
class RealDeviceController extends Notifier<RealDeviceState> {
  final Map<String, BleScanResult> _seen = {};
  StreamSubscription<BleScanResult>? _scanSub;
  StreamSubscription<BleLinkStatus>? _statusSub;
  ControllerService? _service;
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
    ref.listen(axisMappingProvider, (_, m) => _service?.setMapping(m));
    ref.listen(filterKindProvider, (_, k) => _service?.setFilterKind(k));
    ref.onDispose(() {
      _scanSub?.cancel();
      _statusSub?.cancel();
      _statsTimer?.cancel();
      _service?.dispose();
    });
    return RealDeviceState(status: transport.status);
  }

  UniversalBleTransport get _transport => ref.read(realTransportProvider);

  /// The service behind the current connection, for consumers that share its
  /// frame stream (the capture screen). Null before the first connect.
  ControllerService? get service => _service;

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
  Future<void> connect(String deviceId) async {
    await stopScan();
    _update(deviceId: deviceId);
    await _service?.dispose();
    final service = _service = ControllerService(
      _transport,
      deviceId,
      mode: ref.read(streamModeProvider),
      mapping: ref.read(axisMappingProvider),
      filterKind: ref.read(filterKindProvider),
    );
    try {
      await service.start();
    } on BleTransportException {
      return; // already in the status
    } catch (_) {
      return;
    }
    void publish() => state = RealDeviceState(
      status: _transport.status,
      results: state.results,
      deviceId: state.deviceId,
      stats: service.stats,
      mode: service.modeState,
    );
    publish();
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => publish(),
    );
  }

  /// Switches between the raw FF11 and decoded FF12 streams (CCC order is
  /// the transport's job). The choice is remembered for the next connect.
  /// A refusal shows up in [RealDeviceState.mode], never silently.
  Future<void> setStreamMode(StreamMode mode) async {
    ref.read(streamModeProvider.notifier).set(mode);
    final service = _service;
    if (service == null) return;
    await service.setMode(mode);
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
    if (id != null) await _transport.disconnect(id);
  }
}
