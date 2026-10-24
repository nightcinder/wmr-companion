import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_core/ble/ble_transport.dart';
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
    String? deviceId,
    this.connectedDeviceIds = const {},
    this.connectingDeviceIds = const {},
    this.deviceStatuses = const {},
    this.stats,
    this.mode,
    this.disconnectEpoch = 0,
  }) : _primaryDeviceId = deviceId;

  final BleLinkStatus status;

  /// Requested stream and its fault, from the service. Null before connect.
  final ModeState? mode;

  /// Latest sighting per device, strongest signal first.
  final List<BleScanResult> results;

  /// The device we connected to (or lost).
  final String? _primaryDeviceId;
  String? get deviceId => connectedDeviceIds.isNotEmpty
      ? connectedDeviceIds.first
      : (connectingDeviceIds.isNotEmpty
            ? connectingDeviceIds.first
            : _primaryDeviceId);

  /// All currently connected bridges.
  final Set<String> connectedDeviceIds;

  /// Bridges currently in the process of connecting.
  final Set<String> connectingDeviceIds;

  /// Per-device link status.
  final Map<String, BleLinkStatus> deviceStatuses;

  /// Increments on every user-initiated disconnect (one bridge or all).
  ///
  /// Work that should not survive an explicit Disconnect can watch this and
  /// compare it with [connected] instead of trying to tell an intentional
  /// disconnect from a dropped link by the link state alone.
  final int disconnectEpoch;

  final StreamStats? stats;

  bool get scanning => status.phase == BleLinkPhase.scanning;
  bool get connected =>
      connectedDeviceIds.isNotEmpty || status.phase == BleLinkPhase.ready;

  bool isDeviceConnected(String id) => connectedDeviceIds.contains(id);

  bool isDeviceBusy(String id) {
    if (connectingDeviceIds.contains(id)) return true;
    final s = deviceStatuses[id];
    if (s == null) return false;
    return const {
      BleLinkPhase.connecting,
      BleLinkPhase.negotiatingMtu,
      BleLinkPhase.discovering,
      BleLinkPhase.subscribing,
      BleLinkPhase.disconnecting,
    }.contains(s.phase);
  }

  bool get busy =>
      connectingDeviceIds.isNotEmpty ||
      const {
        BleLinkPhase.connecting,
        BleLinkPhase.negotiatingMtu,
        BleLinkPhase.discovering,
        BleLinkPhase.subscribing,
        BleLinkPhase.disconnecting,
      }.contains(status.phase) ||
      deviceStatuses.values.any(
        (s) => const {
          BleLinkPhase.connecting,
          BleLinkPhase.negotiatingMtu,
          BleLinkPhase.discovering,
          BleLinkPhase.subscribing,
          BleLinkPhase.disconnecting,
        }.contains(s.phase),
      );
}

final realDeviceProvider =
    NotifierProvider<RealDeviceController, RealDeviceState>(
      RealDeviceController.new,
    );

/// Timing of the automatic re-dial after an unexpected bridge drop.
///
/// The default is the documented production behaviour: six attempts with
/// 500 ms, 1 s, 2 s, 4 s and 8 s backoff (about 23.5 s in total), then stop
/// and leave the explicit Reconnect button to the user. Tests override it to
/// exercise the cap without waiting for the real delays.
class ReconnectPolicy {
  const ReconnectPolicy({
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
    this.maxAttempts = 6,
  });

  final Duration baseDelay;
  final Duration maxDelay;
  final int maxAttempts;

  /// Delay before attempt [attempt], counting from zero, capped at
  /// [maxDelay].
  Duration delayFor(int attempt) {
    final ms = baseDelay.inMilliseconds << attempt;
    return Duration(
      milliseconds: ms > maxDelay.inMilliseconds ? maxDelay.inMilliseconds : ms,
    );
  }
}

final reconnectPolicyProvider = Provider<ReconnectPolicy>(
  (ref) => const ReconnectPolicy(),
);

/// Drives scan, connect and the [ControllerService] for the real bridge.
class RealDeviceController extends Notifier<RealDeviceState> {
  final Map<String, BleScanResult> _seen = {};
  final Set<String> _connectedDeviceIds = {};
  final Set<String> _connectingDeviceIds = {};
  final Map<String, BleLinkStatus> _deviceStatuses = {};
  final Map<String, Timer> _reconnectTimers = {};
  StreamSubscription<BleScanResult>? _scanSub;
  StreamSubscription<BleLinkStatus>? _statusSub;
  AppLifecycleListener? _lifecycle;
  ControllerService? _service;
  Timer? _statsTimer;
  final Map<String, int> _deviceDisconnectGenerations = {};
  int _globalDisconnectGeneration = 0;
  bool _intentionalDisconnect = false;
  int _disconnectEpoch = 0;

  final Map<String, int> _reconnectAttempts = {};
  final Set<String> _reconnecting = {};

  @override
  RealDeviceState build() {
    final transport = ref.watch(realTransportProvider);
    _statusSub = transport.statusChanges.listen((s) {
      if (s.deviceId != null) {
        final id = s.deviceId!;
        _deviceStatuses[id] = s;
        if (s.phase == BleLinkPhase.ready) {
          _connectedDeviceIds.add(id);
          _connectingDeviceIds.remove(id);
          _reconnectAttempts.remove(id);
          _reconnecting.remove(id);
        } else if (s.phase == BleLinkPhase.disconnected ||
            s.phase == BleLinkPhase.disconnecting ||
            s.phase == BleLinkPhase.connectionLost ||
            s.isFailure) {
          _connectedDeviceIds.remove(id);
          _connectingDeviceIds.remove(id);
          unawaited(_service?.removeDevice(id, disconnectTransport: false));
          if (_connectedDeviceIds.isEmpty && _connectingDeviceIds.isEmpty) {
            _statsTimer?.cancel();
            unawaited(_service?.dispose());
            _service = null;
          }
          if (!_intentionalDisconnect) {
            if (s.phase == BleLinkPhase.connectionLost) {
              // The link dropped on its own: start a fresh retry campaign.
              _scheduleReconnect(id);
            } else if (s.isFailure && _reconnecting.contains(id)) {
              // An automatic re-dial failed. Keep trying with backoff until
              // the attempt cap, otherwise one transient failure would leave
              // the bridge un-dialled for good.
              _scheduleReconnect(id);
            }
          }
        }
      }
      final effectiveStatus = _connectedDeviceIds.isNotEmpty
          ? (_deviceStatuses[_connectedDeviceIds.first] ?? s)
          : s;
      _update(status: effectiveStatus);
    });

    _lifecycle?.dispose();
    final lifecycle = _lifecycle = AppLifecycleListener(
      onStateChange: (s) => unawaited(
        transport.handleAppLifecycle(switch (s) {
          AppLifecycleState.resumed => BleAppLifecycle.resumed,
          AppLifecycleState.inactive => BleAppLifecycle.inactive,
          AppLifecycleState.paused => BleAppLifecycle.paused,
          AppLifecycleState.detached => BleAppLifecycle.detached,
          AppLifecycleState.hidden => BleAppLifecycle.inactive,
        }),
      ),
    );

    ref.listen(axisMappingProvider, (_, m) => _service?.setMapping(m));
    ref.listen(filterKindProvider, (_, k) => _service?.setFilterKind(k));
    ref.listen(
      filterTuningProvider,
      (_, tuning) => _service?.setFilterTuning(tuning),
    );
    ref.listen(
      stickSettingsProvider.select((s) => s.config),
      (_, c) => _service?.setStickConfig(c),
    );
    ref.listen(stickSettingsProvider.select((s) => s.centres), (_, centres) {
      final service = _service;
      if (service != null) applyStickCentres(service, centres);
    });
    ref.listen(ff13SettingsProvider, (_, s) {
      final service = _service;
      if (service != null) applyFf13Settings(service, s);
    });
    ref.onDispose(() {
      lifecycle.dispose();
      _scanSub?.cancel();
      _statusSub?.cancel();
      _statsTimer?.cancel();
      for (final t in _reconnectTimers.values) {
        t.cancel();
      }
      _reconnectTimers.clear();
      _reconnectAttempts.clear();
      _reconnecting.clear();
      _service?.dispose();
    });
    return RealDeviceState(status: transport.status);
  }

  UniversalBleTransport get _transport => ref.read(realTransportProvider);

  /// The service behind the current connection, for consumers that share its
  /// frame stream (the capture screen). Null before the first connect.
  ControllerService? get service => _service;

  void _scheduleReconnect(String id) {
    if (_intentionalDisconnect) return;
    _reconnectTimers[id]?.cancel();
    final policy = ref.read(reconnectPolicyProvider);
    final attempt = _reconnectAttempts[id] ?? 0;
    if (attempt >= policy.maxAttempts) {
      _reconnectAttempts.remove(id);
      _reconnecting.remove(id);
      return;
    }
    _reconnectAttempts[id] = attempt + 1;
    _reconnecting.add(id);
    _reconnectTimers[id] = Timer(policy.delayFor(attempt), () async {
      _reconnectTimers.remove(id);
      if (_intentionalDisconnect) {
        _reconnecting.remove(id);
        return;
      }
      await connect(id);
    });
  }

  void _update({
    BleLinkStatus? status,
    List<BleScanResult>? results,
    String? deviceId,
  }) {
    final activeStatus =
        status ??
        (_connectedDeviceIds.isNotEmpty
            ? (_deviceStatuses[_connectedDeviceIds.first] ?? _transport.status)
            : _transport.status);
    state = RealDeviceState(
      status: activeStatus,
      results: results ?? state.results,
      deviceId:
          deviceId ??
          (_connectedDeviceIds.isNotEmpty
              ? _connectedDeviceIds.first
              : (_connectingDeviceIds.isNotEmpty
                    ? _connectingDeviceIds.first
                    : state.deviceId)),
      connectedDeviceIds: Set.unmodifiable(_connectedDeviceIds),
      connectingDeviceIds: Set.unmodifiable(_connectingDeviceIds),
      deviceStatuses: Map.unmodifiable(_deviceStatuses),
      stats: _service?.stats ?? state.stats,
      mode: _service?.modeState ?? state.mode,
      disconnectEpoch: _disconnectEpoch,
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
    if (_connectedDeviceIds.contains(deviceId) ||
        _connectingDeviceIds.contains(deviceId)) {
      return;
    }
    await stopScan();
    final deviceDisconnectGen = _deviceDisconnectGenerations[deviceId] ?? 0;
    final globalDisconnectGen = _globalDisconnectGeneration;
    _connectingDeviceIds.add(deviceId);
    _update(deviceId: deviceId);
    try {
      if (_service == null) {
        final settings = ref.read(stickSettingsProvider);
        final service = _service = ControllerService(
          _transport,
          [deviceId],
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
        try {
          await service.start();
        } on BleTransportException {
          _connectedDeviceIds.remove(deviceId);
          _service?.dispose();
          _service = null;
          _update();
          return; // already in the status
        } catch (_) {
          _connectedDeviceIds.remove(deviceId);
          _service?.dispose();
          _service = null;
          _update();
          return;
        }
      } else {
        try {
          await _service!.addDevice(deviceId);
        } on BleTransportException {
          _connectedDeviceIds.remove(deviceId);
          _update();
          return;
        } catch (_) {
          _connectedDeviceIds.remove(deviceId);
          _update();
          return;
        }
      }

      // Check if disconnect was called for this device or all devices:
      if ((_deviceDisconnectGenerations[deviceId] ?? 0) !=
              deviceDisconnectGen ||
          globalDisconnectGen != _globalDisconnectGeneration) {
        await _transport.disconnect(deviceId);
        return;
      }
    } finally {
      _connectingDeviceIds.remove(deviceId);
      _update();
    }

    void publish() => _update();
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
    final service = _service;
    if (service == null) return;
    await service.setMode(mode);
    _update();
  }

  Future<void> disconnect([String? deviceId]) async {
    if (deviceId != null) {
      _deviceDisconnectGenerations[deviceId] =
          (_deviceDisconnectGenerations[deviceId] ?? 0) + 1;
      _reconnectTimers.remove(deviceId)?.cancel();
      _reconnectAttempts.remove(deviceId);
      _reconnecting.remove(deviceId);
      _disconnectEpoch++;

      _connectingDeviceIds.remove(deviceId);
      _connectedDeviceIds.remove(deviceId);
      _deviceStatuses.remove(deviceId);
      await _service?.removeDevice(deviceId);
      if (_connectedDeviceIds.isEmpty && _connectingDeviceIds.isEmpty) {
        _statsTimer?.cancel();
        await _service?.dispose();
        _service = null;
      }
      try {
        await _transport.disconnect(deviceId);
      } catch (_) {}
      _update();
      return;
    }

    _globalDisconnectGeneration++;
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    _reconnectAttempts.clear();
    _reconnecting.clear();
    _disconnectEpoch++;

    _intentionalDisconnect = true;
    try {
      _statsTimer?.cancel();
      await _service?.dispose();
      _service = null;
      final toDisconnect = {..._connectedDeviceIds, ..._connectingDeviceIds};
      _connectingDeviceIds.clear();
      _connectedDeviceIds.clear();
      _deviceStatuses.clear();
      for (final id in toDisconnect) {
        try {
          await _transport.disconnect(id);
        } catch (_) {}
      }
      _update();
    } finally {
      _intentionalDisconnect = false;
    }
  }
}
