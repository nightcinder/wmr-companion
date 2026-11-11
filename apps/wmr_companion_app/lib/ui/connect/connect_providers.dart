import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion/wmr_companion.dart'
    show CompositeBleTransport, CompositeLeg;
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/firmware_version.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_ws/wmr_ws.dart';

import '../debug/stream_settings.dart';

/// The real BLE transport. Created on first use, so the fake-bridge path
/// never touches the Bluetooth plugin. Tests override it with a transport on
/// a fake adapter.
final realTransportProvider = Provider<UniversalBleTransport>((ref) {
  final transport = UniversalBleTransport(adapter: UniversalBleAdapter());
  ref.onDispose(transport.dispose);
  return transport;
});

/// Builds the BLE-first composite used by the Bluetooth tab.
///
/// No TCP endpoint is known before the bridge answers FF16 with its endpoint
/// document, so [CompositeBleTransport.connect] dials BLE and learns the LAN
/// hosts there. The same session then upgrades to TCP/Wi-Fi, with BLE left as
/// the fallback.
final bleHandoffTransportFactoryProvider =
    Provider<BleTransport Function(BleTransport ble)>(
      (ref) =>
          (ble) => CompositeBleTransport(
            tcp: WmrWsTransport(endpoints: const []),
            ble: ble,
            // The shared BLE transport outlives the composite and is disposed
            // by [realTransportProvider].
            disposeBle: false,
          ),
    );

/// The BLE-first composite behind the Bluetooth tab, built on the shared BLE
/// transport. Created on first use, so the fake-bridge path never touches the
/// Bluetooth plugin.
final bleHandoffTransportProvider = Provider<BleTransport>((ref) {
  final transport = ref.watch(bleHandoffTransportFactoryProvider)(
    ref.watch(realTransportProvider),
  );
  ref.onDispose(transport.dispose);
  return transport;
});

/// Which link a bridge is connected over. The device id stays the existing
/// `bridgeId`; this only labels it in the UI.
enum BridgeTransportKind { ble, wifi }

extension BridgeTransportKindLabel on BridgeTransportKind {
  String get label => switch (this) {
    BridgeTransportKind.ble => 'BLE',
    BridgeTransportKind.wifi => 'Wi-Fi',
  };

  /// The row label, with the active leg of a TCP/BLE composite Wi-Fi link.
  String labelWithLeg(WifiLinkLeg? wifiLeg) => switch (this) {
    BridgeTransportKind.ble => label,
    BridgeTransportKind.wifi =>
      wifiLeg == null ? label : 'Wi-Fi (${wifiLeg.label})',
  };
}

/// The transport behind each bridge id, published by [RealDeviceController]
/// when it connects. Debug and latency screens read it to label a bridge
/// without renaming or extending [BleTransport].
final bridgeTransportKindsProvider =
    NotifierProvider<BridgeTransportKinds, Map<String, BridgeTransportKind>>(
      BridgeTransportKinds.new,
    );

class BridgeTransportKinds extends Notifier<Map<String, BridgeTransportKind>> {
  @override
  Map<String, BridgeTransportKind> build() => const {};

  void set(String bridgeId, BridgeTransportKind kind) {
    if (state[bridgeId] == kind) return;
    state = {...state, bridgeId: kind};
  }

  void remove(String bridgeId) {
    if (!state.containsKey(bridgeId)) return;
    state = Map.of(state)..remove(bridgeId);
  }
}

/// Builds a Wi-Fi transport for one host:port endpoint. Production uses the
/// real WebSocket client; tests override this with a transport on a fake
/// adapter so no socket is opened.
final wifiTransportFactoryProvider =
    Provider<BleTransport Function(WmrWsEndpoint)>(
      (ref) =>
          (endpoint) => WmrWsTransport(endpoints: [endpoint]),
    );

/// Which leg of an opt-in fallback link is carrying the bridge.
enum WifiLinkLeg { tcp, ble }

extension WifiLinkLegLabel on WifiLinkLeg {
  String get label => switch (this) {
    WifiLinkLeg.tcp => 'TCP',
    WifiLinkLeg.ble => 'BLE',
  };
}

/// The leg carrying an opt-in TCP/BLE composite Wi-Fi link, null for a plain
/// Wi-Fi link or while the composite is still choosing one.
///
/// Debug and latency rows read it so they can say `Wi-Fi (TCP)` instead of a
/// bare `Wi-Fi` while a fallback link is active.
final activeWifiLegProvider = Provider<WifiLinkLeg?>(
  (ref) => ref.watch(
    realDeviceProvider.select((s) => s.wifiFallback ? s.wifiLeg : null),
  ),
);

/// A Wi-Fi link and, for the opt-in composite, the leg currently in use.
class WifiLink {
  const WifiLink(this.transport, {this.activeLeg});

  final BleTransport transport;

  /// Read on each state update, so a composite failover is reflected without
  /// waiting for a connection-state change (the state stays `connected`).
  final WifiLinkLeg? Function()? activeLeg;
}

/// Builds the TCP-first link with a BLE GATT fallback.
///
/// Production gives the composite its own BLE transport: the composite owns
/// and disposes it, so it cannot tear down the Bluetooth screen's transport.
/// Tests override this factory with a fake link.
final compositeWifiTransportFactoryProvider =
    Provider<WifiLink Function(WmrWsEndpoint)>((ref) {
      return (endpoint) {
        final composite = CompositeBleTransport(
          tcp: WmrWsTransport(endpoints: [endpoint]),
          ble: UniversalBleTransport(adapter: UniversalBleAdapter()),
        );
        return WifiLink(
          composite,
          activeLeg: () =>
              switch (composite.activeLegFor(endpoint.resolvedDeviceId)) {
                CompositeLeg.tcp => WifiLinkLeg.tcp,
                CompositeLeg.ble => WifiLinkLeg.ble,
                null => null,
              },
        );
      };
    });

/// One LAN discovery pass. Production runs [WmrWsDiscovery]; tests replace it
/// with a fixed list so no socket is opened.
final lanDiscoveryProvider = Provider<Future<List<WmrWsEndpoint>> Function()>(
  (ref) => WmrWsDiscovery().discover,
);

/// The transport behind the selected link, recomputed when the link or its
/// Wi-Fi device changes. Debug screens read live parameters through it.
final realLinkTransportProvider = Provider<BleTransport>((ref) {
  final kind = ref.watch(realDeviceProvider.select((s) => s.activeTransport));
  final wifiDeviceId = ref.watch(
    realDeviceProvider.select((s) => s.wifiDeviceId),
  );
  if (kind == BridgeTransportKind.wifi && wifiDeviceId != null) {
    return ref.read(realDeviceProvider.notifier).wifiTransport ??
        ref.read(realTransportProvider);
  }
  // The Bluetooth tab dials through the handoff composite, so that is the
  // transport whose clock stamped the frames the debug panels display.
  return ref.read(realDeviceProvider.notifier).transport;
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
    this.decodedStats,
    this.mode,
    this.protocol,
    this.protocolUnavailable = false,
    this.disconnectEpoch = 0,
    this.activeTransport = BridgeTransportKind.ble,
    this.wifiDeviceId,
    this.wifiFallback = false,
    this.wifiLeg,
    this.lanEndpoints = const [],
    this.discoveringLan = false,
    this.lanError,
  }) : _primaryDeviceId = deviceId;

  final BleLinkStatus status;

  /// The link selected in the connect screen. Only one transport is active at
  /// a time: connecting Wi-Fi disconnects the BLE bridges, and vice versa.
  final BridgeTransportKind activeTransport;

  /// The Wi-Fi bridge id, once a Wi-Fi transport exists. Null in BLE mode.
  final String? wifiDeviceId;

  /// Whether the current Wi-Fi link is the opt-in TCP/BLE composite.
  final bool wifiFallback;

  /// Active leg of a [wifiFallback] link. Null otherwise, or while the
  /// composite is still choosing one.
  final WifiLinkLeg? wifiLeg;

  /// Endpoints from the most recent LAN discovery pass.
  final List<WmrWsEndpoint> lanEndpoints;

  /// True while a LAN discovery pass is running.
  final bool discoveringLan;

  /// Why the last LAN discovery pass failed, if it did.
  final String? lanError;

  /// Requested stream and its fault, from the service. Null before connect.
  final ModeState? mode;

  /// FF16 version and feature matrix of the primary connected bridge. Null
  /// while the one-time read after connect is in flight, after a disconnect,
  /// and when discovery failed.
  final WmrProtocolVersion? protocol;

  /// True when protocol discovery failed, so [protocol] will stay null
  /// instead of a read landing later.
  final bool protocolUnavailable;

  /// The primary connected bridge's FF16 version, when it reported one.
  String? get firmwareVersion => protocol?.firmwareVersion;

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

  /// FF12/FF14 figures, so the Stream panel is not blank in a decoded mode.
  final DecodedStats? decodedStats;

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

  WifiLink? _wifiLink;
  BleTransport? _wifiTransport;
  StreamSubscription<BleConnectionState>? _wifiStateSub;
  StreamSubscription<BleScanResult>? _fallbackScanSub;
  String? _wifiDeviceId;
  BleLinkStatus _lastStatus = const BleLinkStatus(BleLinkPhase.idle);

  @override
  RealDeviceState build() {
    final transport = ref.watch(realTransportProvider);
    _statusSub = transport.statusChanges.listen(_handleBleLinkStatus);
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
      _wifiStateSub?.cancel();
      _fallbackScanSub?.cancel();
      _statsTimer?.cancel();
      for (final t in _reconnectTimers.values) {
        t.cancel();
      }
      _reconnectTimers.clear();
      _reconnectAttempts.clear();
      _reconnecting.clear();
      _service?.dispose();
      _wifiTransport?.dispose();
    });
    return RealDeviceState(status: transport.status);
  }

  /// The active link: the BLE handoff composite, or the Wi-Fi transport once
  /// one is configured. [BleTransport] stays the seam for both.
  ///
  /// The Bluetooth tab goes through [CompositeBleTransport] too, so its
  /// FF16/FF13 reads start the automatic upgrade to TCP/Wi-Fi.
  BleTransport get _transport =>
      state.activeTransport == BridgeTransportKind.wifi &&
          _wifiTransport != null
      ? _wifiTransport!
      : _bleHandoffTransport;

  BleTransport get _bleHandoffTransport =>
      ref.read(bleHandoffTransportProvider);

  /// The transport behind the current link, for consumers that need to read
  /// the same device (the debug config panel).
  BleTransport get transport => _transport;

  /// The Wi-Fi transport, once [connectWifi] has made one. Null in BLE mode.
  BleTransport? get wifiTransport => _wifiTransport;

  /// The service behind the current connection, for consumers that share its
  /// frame stream (the capture screen). Null before the first connect.
  ControllerService? get service => _service;

  /// One place for a link status, whether it came from the BLE stack or was
  /// synthesized from a Wi-Fi connection state.
  ///
  /// The Bluetooth tab's transport is the handoff composite, which keeps the
  /// GATT link open as a fallback after it upgrades the session to TCP. A raw
  /// BLE event for that device therefore only describes the fallback leg, not
  /// the session: a radio drop while TCP carries it must not tear the session
  /// down.
  void _handleBleLinkStatus(BleLinkStatus s) {
    final id = s.deviceId;
    final active = transport;
    if (id != null &&
        active is CompositeBleTransport &&
        active.activeLegFor(id) == CompositeLeg.tcp) {
      return;
    }
    _handleLinkStatus(s);
  }

  void _handleLinkStatus(BleLinkStatus s) {
    if (state.activeTransport == BridgeTransportKind.wifi &&
        s.deviceId != null &&
        s.deviceId != _wifiDeviceId) {
      // A late BLE event from the link we switched away from.
      return;
    }
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
    _lastStatus = s;
    final effectiveStatus = _connectedDeviceIds.isNotEmpty
        ? (_deviceStatuses[_connectedDeviceIds.first] ?? s)
        : s;
    _update(status: effectiveStatus);
  }

  void _onWifiConnectionState(String id, BleConnectionState s) {
    if (_wifiDeviceId != id) return;
    switch (s) {
      case BleConnectionState.connected:
        // [connect] promotes to ready after the stream subscription succeeds,
        // exactly as the BLE transport's status does.
        return;
      case BleConnectionState.connecting:
        _handleLinkStatus(BleLinkStatus(BleLinkPhase.connecting, deviceId: id));
      case BleConnectionState.disconnecting:
        _handleLinkStatus(
          BleLinkStatus(BleLinkPhase.disconnecting, deviceId: id),
        );
      case BleConnectionState.disconnected:
        final wasReady = _connectedDeviceIds.contains(id);
        _handleLinkStatus(
          BleLinkStatus(
            wasReady ? BleLinkPhase.connectionLost : BleLinkPhase.disconnected,
            deviceId: id,
          ),
        );
    }
  }

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
    BridgeTransportKind? activeTransport,
    bool? wifiFallback,
    List<WmrWsEndpoint>? lanEndpoints,
    bool? discoveringLan,
    String? lanError,
    bool clearLanError = false,
  }) {
    final activeStatus =
        status ??
        (_connectedDeviceIds.isNotEmpty
            ? (_deviceStatuses[_connectedDeviceIds.first] ?? _lastStatus)
            : _lastStatus);
    final nextTransport = activeTransport ?? state.activeTransport;
    final primaryId = _connectedDeviceIds.isNotEmpty
        ? _connectedDeviceIds.first
        : null;
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
      decodedStats: _service?.decodedStats ?? state.decodedStats,
      mode: _service?.modeState ?? state.mode,
      protocol: primaryId == null ? null : _service?.protocolFor(primaryId),
      protocolUnavailable:
          primaryId != null &&
          (_service?.protocolUnavailableFor(primaryId) ?? false),
      disconnectEpoch: _disconnectEpoch,
      activeTransport: nextTransport,
      wifiDeviceId: _wifiDeviceId,
      wifiFallback:
          nextTransport == BridgeTransportKind.wifi &&
          (wifiFallback ?? state.wifiFallback),
      wifiLeg: nextTransport == BridgeTransportKind.wifi
          ? _wifiLink?.activeLeg?.call()
          : null,
      lanEndpoints: lanEndpoints ?? state.lanEndpoints,
      discoveringLan: discoveringLan ?? state.discoveringLan,
      lanError: clearLanError ? null : (lanError ?? state.lanError),
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
      ref
          .read(bridgeTransportKindsProvider.notifier)
          .set(r.deviceId, state.activeTransport);
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
    // A Wi-Fi composite may be scanning to learn its BLE fallback candidate;
    // that scan must outlive the dial. BLE mode still stops its scan here.
    if (state.activeTransport != BridgeTransportKind.wifi) {
      await stopScan();
    }
    final deviceDisconnectGen = _deviceDisconnectGenerations[deviceId] ?? 0;
    final globalDisconnectGen = _globalDisconnectGeneration;
    _connectingDeviceIds.add(deviceId);
    ref
        .read(bridgeTransportKindsProvider.notifier)
        .set(deviceId, state.activeTransport);
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
        } catch (error) {
          _connectedDeviceIds.remove(deviceId);
          _service?.dispose();
          _service = null;
          _reportWifiFailure(deviceId, error);
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
        } catch (error) {
          _connectedDeviceIds.remove(deviceId);
          _reportWifiFailure(deviceId, error);
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
      if (state.activeTransport == BridgeTransportKind.wifi &&
          _wifiTransport != null) {
        await _promoteWifiReady(deviceId);
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

  void _reportWifiFailure(String deviceId, Object error) {
    if (state.activeTransport != BridgeTransportKind.wifi) return;
    _handleLinkStatus(
      BleLinkStatus(
        BleLinkPhase.connectFailed,
        deviceId: deviceId,
        message: '$error',
      ),
    );
  }

  Future<void> _promoteWifiReady(String deviceId) async {
    int? mtu;
    try {
      mtu = (await _transport.connectionInfo(deviceId)).mtu;
    } catch (_) {
      // The figures are optional; the link is up either way.
    }
    _handleLinkStatus(
      BleLinkStatus(BleLinkPhase.ready, deviceId: deviceId, mtu: mtu),
    );
  }

  Future<void> _disposeWifiTransport() async {
    final id = _wifiDeviceId;
    _wifiDeviceId = null;
    final sub = _wifiStateSub;
    _wifiStateSub = null;
    final scanSub = _fallbackScanSub;
    _fallbackScanSub = null;
    final transport = _wifiTransport;
    _wifiTransport = null;
    _wifiLink = null;
    if (id != null) {
      ref.read(bridgeTransportKindsProvider.notifier).remove(id);
    }
    // Cancelling the async* connection-state stream can wait on a delivery
    // turn; the id guard above already makes late events harmless.
    unawaited(sub?.cancel());
    unawaited(scanSub?.cancel());
    await transport?.dispose();
  }

  /// Scans through the composite so its `_scanHits` hold the BLE bridge that
  /// a TCP failure can fall back to. The scan keeps running after a successful
  /// TCP dial (until the transport's own scan timeout), so a later drop has a
  /// candidate; the composite keeps the hits after the scan stops.
  void _startFallbackScan(BleTransport transport) {
    unawaited(_fallbackScanSub?.cancel());
    _fallbackScanSub = transport.scan().listen((_) {}, onError: (Object _) {});
  }

  Future<void> _stopFallbackScan() async {
    final sub = _fallbackScanSub;
    _fallbackScanSub = null;
    // Cancelling can wait on a delivery turn; the scan is best-effort and the
    // transport stop below is what actually ends it.
    unawaited(sub?.cancel());
    // Stop the radio; the hits already seen stay with the composite.
    final transport = _wifiTransport;
    if (transport != null) {
      try {
        await transport.stopScan();
      } catch (_) {
        // A disposed transport has nothing left to stop.
      }
    }
  }

  /// Chooses the link the connect screen shows. Only one link is active at a
  /// time; switching disconnects what the other one had.
  Future<void> selectTransport(BridgeTransportKind kind) async {
    if (state.activeTransport == kind) return;
    await stopScan();
    await disconnect();
    if (kind == BridgeTransportKind.ble) {
      await _disposeWifiTransport();
    }
    _lastStatus = const BleLinkStatus(BleLinkPhase.idle);
    _update(activeTransport: kind);
  }

  /// Runs one LAN discovery pass and publishes the results. Best-effort:
  /// no network means an empty list, and a failure is shown in state rather
  /// than thrown at the tap.
  Future<void> discoverLan() async {
    if (state.discoveringLan) return;
    _update(discoveringLan: true, clearLanError: true);
    try {
      final found = await ref.read(lanDiscoveryProvider)();
      _update(lanEndpoints: found);
    } catch (error) {
      _update(lanError: '$error');
    } finally {
      _update(discoveringLan: false);
    }
  }

  /// Connects to a Pi Wi-Fi bridge by host:port, with the optional shared
  /// token. The token is only handed to the transport; it is never logged or
  /// kept in app state.
  ///
  /// [bridgeId] and [name] come from LAN discovery and let the transport
  /// verify the WebSocket `hello` before sending a token. [candidateHosts]
  /// carries the other interface addresses discovery reported for the same
  /// bridge, so the transport can fall back when [host] is unreachable.
  /// [bleFallback] defaults to the TCP-first [CompositeBleTransport] instead
  /// of a plain WebSocket, so the same session can stay up over BLE and the
  /// FF16 endpoint document can complete the upgrade.
  Future<void> connectWifi({
    required String host,
    required int port,
    String? token,
    bool secure = false,
    String? path,
    String? bridgeId,
    String? name,
    Iterable<String> candidateHosts = const <String>[],
    bool bleFallback = true,
  }) async {
    final trimmedToken = token?.trim();
    final endpoint = WmrWsEndpoint(
      host: host.trim(),
      candidateHosts: candidateHosts,
      port: port,
      path: path ?? wmrWsDefaultPath,
      secure: secure,
      bridgeId: bridgeId,
      name: name,
      token: trimmedToken == null || trimmedToken.isEmpty ? null : trimmedToken,
    );
    final id = endpoint.resolvedDeviceId;

    await disconnect();
    await _disposeWifiTransport();
    _lastStatus = const BleLinkStatus(BleLinkPhase.connecting);
    _wifiDeviceId = id;
    final link = bleFallback
        ? ref.read(compositeWifiTransportFactoryProvider)(endpoint)
        : WifiLink(ref.read(wifiTransportFactoryProvider)(endpoint));
    _wifiLink = link;
    final transport = _wifiTransport = link.transport;
    _wifiStateSub = transport
        .connectionState(id)
        .listen((s) => _onWifiConnectionState(id, s));
    ref
        .read(bridgeTransportKindsProvider.notifier)
        .set(id, BridgeTransportKind.wifi);
    _update(
      activeTransport: BridgeTransportKind.wifi,
      wifiFallback: bleFallback,
    );
    if (bleFallback) _startFallbackScan(transport);
    await connect(id);
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

    await _stopFallbackScan();
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

/// The running app's version, e.g. `0.3.0+5`. Shown on the scan screen so
/// testers can quote it in bug reports. A platform failure degrades to
/// `unknown` rather than hiding the label.
final appVersionProvider = FutureProvider<String>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.buildNumber.isEmpty
        ? info.version
        : '${info.version}+${info.buildNumber}';
  } catch (_) {
    return 'unknown';
  }
});

/// The GitHub Releases endpoint for the latest Pi bridge release.
const String bridgeLatestReleaseUrl =
    'https://api.github.com/repos/nightcinder/WMR_Bridge/releases/latest';

/// Reads the latest WMR_Bridge release tag and caches it for the session.
///
/// The Connect screen needs a yes/no answer ("is there a newer release?"), so
/// a failed request, an offline device, or a malformed response all degrade
/// to null instead of surfacing an error. [fetch] and [clock] are injectable
/// for tests; [cacheFor] keeps repeat screen builds from re-querying GitHub.
class BridgeReleaseChecker {
  BridgeReleaseChecker({
    Future<String?> Function(Uri uri)? fetch,
    DateTime Function()? clock,
    this.cacheFor = const Duration(hours: 1),
  }) : _fetch = fetch ?? _fetchLatestReleaseDocument,
       _clock = clock ?? DateTime.now;

  final Future<String?> Function(Uri uri) _fetch;
  final DateTime Function() _clock;
  final Duration cacheFor;

  ({DateTime at, WmrSemanticVersion version})? _cached;

  /// The latest release tag, or null when it could not be read.
  Future<WmrSemanticVersion?> latest() async {
    final cached = _cached;
    if (cached != null && _clock().difference(cached.at) < cacheFor) {
      return cached.version;
    }
    try {
      final body = await _fetch(Uri.parse(bridgeLatestReleaseUrl));
      if (body == null) return null;
      final version = parseLatestRelease(body);
      if (version != null) _cached = (at: _clock(), version: version);
      return version;
    } catch (_) {
      // Offline, DNS failure or a timeout: no banner rather than an error.
      return null;
    }
  }

  /// Parses the `tag_name` of a GitHub `releases/latest` response.
  static WmrSemanticVersion? parseLatestRelease(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final tag = decoded['tag_name'];
    return tag is String ? WmrSemanticVersion.tryParse(tag) : null;
  }

  static Future<String?> _fetchLatestReleaseDocument(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(uri);
      // GitHub rejects API requests that do not identify a client.
      request.headers.set(HttpHeaders.userAgentHeader, 'wmr-companion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }
}

/// The release checker for this session. Tests override it with a fake.
final bridgeReleaseCheckerProvider = Provider<BridgeReleaseChecker>(
  (ref) => BridgeReleaseChecker(),
);

/// The latest WMR_Bridge release, null while unknown or offline.
final latestBridgeReleaseProvider = FutureProvider<WmrSemanticVersion?>(
  (ref) => ref.watch(bridgeReleaseCheckerProvider).latest(),
);
