import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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

import '../../services/app_installer.dart';
import '../../services/app_release_checker.dart';
import '../../services/bridge_token_store.dart';
import '../../services/bridge_update_settings_store.dart';
import '../../services/known_bridge_store.dart';
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
            // With Wi-Fi off the Pi's LAN address cannot answer; probe the
            // interfaces first so the BLE dial is not held up by TCP.
            lanAvailable: () => ref.read(lanInterfaceProbeProvider)(),
            // The shared BLE transport outlives the composite and is disposed
            // by [realTransportProvider].
            disposeBle: false,
            onTokenLearned: (bridgeId, hosts, port, token) {
              unawaited(
                ref
                    .read(bridgeTokenStoreProvider)
                    .save(bridgeId: bridgeId, hosts: hosts, token: token),
              );
              unawaited(_rememberLearnedBridge(ref, bridgeId, hosts, port));
            },
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
          // No Wi-Fi: skip the TCP probe so the BLE leg is dialled at once
          // instead of waiting out the remembered LAN address.
          lanAvailable: () => ref.read(lanInterfaceProbeProvider)(),
          onTokenLearned: (bridgeId, hosts, port, token) {
            unawaited(
              ref
                  .read(bridgeTokenStoreProvider)
                  .save(bridgeId: bridgeId, hosts: hosts, token: token),
            );
            unawaited(_rememberLearnedBridge(ref, bridgeId, hosts, port));
          },
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

/// Saves the endpoint a BLE FF13/FF16 exchange discovered, so the next launch
/// reconnects to that bridge by default instead of waiting for a scan.
///
/// The token is stored separately in secure storage; this only remembers the
/// address. Losing the memory costs one discovery pass, not the connection.
Future<void> _rememberLearnedBridge(
  Ref ref,
  String bridgeId,
  List<String> hosts,
  int port,
) async {
  if (bridgeId.trim().isEmpty || hosts.isEmpty) return;
  try {
    await ref
        .read(knownBridgeStoreProvider)
        .save(KnownBridge(bridgeId: bridgeId, hosts: hosts, port: port));
  } catch (_) {
    // Nothing saved, or no storage on this platform.
  }
}

/// The latest WMR_Bridge release can be installed from the Pi itself when its
/// daemon advertises `upgradeCapable`. Older daemons need this one-liner.
const String bridgeManualUpgradeCommand =
    'curl -fsSL '
    'https://github.com/nightcinder/WMR_Bridge/releases/latest/download/install.sh'
    ' | sudo bash';

/// Human-readable reason for a failed Wi-Fi dial.
///
/// A token failure names the file on the Pi and the Bluetooth path that can
/// learn it. The token itself is never included in the message.
String wifiFailureMessage(Object error) => switch (error) {
  WmrWsAuthException(failure: WmrWsAuthFailure.noToken) =>
    'This bridge requires a token. Type the one from '
        '/etc/wmr-bridge/token on the Pi, or connect once over Bluetooth '
        'so the app can read and save it.',
  WmrWsAuthException(failure: WmrWsAuthFailure.rejected) =>
    'The bridge rejected the token. Compare it with '
        '/etc/wmr-bridge/token on the Pi.',
  WmrWsAuthException(failure: WmrWsAuthFailure.timeout) =>
    'The bridge did not answer authentication. Check the token and retry.',
  _ => '$error',
};

/// What the Connect screen shows for an in-app bridge upgrade.
enum BridgeUpgradePhase { idle, sending, restarting, busy, failed }

class BridgeUpgradeState {
  const BridgeUpgradeState(this.phase, {this.message});

  const BridgeUpgradeState.idle()
    : phase = BridgeUpgradePhase.idle,
      message = null;

  final BridgeUpgradePhase phase;

  /// Human-readable result of the last upgrade request, or null while idle.
  final String? message;

  bool get isActive =>
      phase == BridgeUpgradePhase.sending ||
      phase == BridgeUpgradePhase.restarting;
}

/// One LAN discovery pass. Production runs [WmrWsDiscovery]; tests replace it
/// with a fixed list so no socket is opened.
final lanDiscoveryProvider = Provider<Future<List<WmrWsEndpoint>> Function()>(
  (ref) => WmrWsDiscovery().discover,
);

/// Whether a LAN interface is up right now.
///
/// Wi-Fi off leaves only loopback (or mobile data, which cannot reach the Pi),
/// so a WebSocket dial to the Pi's LAN address can only run down its timeouts
/// while Bluetooth is the only working link. The transport composites consult
/// this before probing TCP. Tests replace it with a fixed answer.
final lanInterfaceProbeProvider = Provider<Future<bool> Function()>(
  (ref) => hasLanInterface,
);

/// Interface name prefixes that are never a LAN the Pi is reachable on:
/// Android/iOS mobile data, VPN tunnels and peer-to-peer links.
const List<String> _nonLanInterfacePrefixes = [
  'rmnet',
  'ccmni',
  'pdp',
  'clat',
  'dummy',
  'tun',
  'utun',
  'ppp',
  'ipsec',
  'awdl',
  'llw',
];

/// Whether [name] is an interface a LAN bridge can be dialled on.
///
/// Mobile data, VPN and peer-to-peer interfaces carry a non-loopback address
/// too, but mDNS and a direct WebSocket to the Pi's LAN address do not work
/// over them.
bool isLanInterfaceName(String name) {
  final lower = name.toLowerCase();
  return !_nonLanInterfacePrefixes.any(lower.startsWith);
}

/// Whether an active, non-loopback LAN interface exists.
///
/// A platform that cannot list interfaces answers true: guessing "no LAN"
/// would disable Wi-Fi for everyone. Both IPv4 and IPv6 addresses count, so an
/// IPv6-only Wi-Fi link is not mistaken for a missing LAN.
Future<bool> hasLanInterface() async {
  try {
    final interfaces = await NetworkInterface.list(includeLoopback: false);
    return interfaces.any(
      (interface) =>
          interface.addresses.isNotEmpty && isLanInterfaceName(interface.name),
    );
  } catch (_) {
    return true;
  }
}

/// Whether the Connect screen runs the launch-time LAN scan and auto-dial.
/// Tests that exercise other screen behaviour override it to false.
final launchAutoConnectEnabledProvider = Provider<bool>((ref) => true);

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
    this.bridgeUpgrade = const BridgeUpgradeState.idle(),
    this.bridgeUpgradeCapable = false,
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

  /// Progress and result of the last in-app bridge upgrade request.
  final BridgeUpgradeState bridgeUpgrade;

  /// Whether the connected Wi-Fi daemon advertised `upgradeCapable` and the
  /// TCP leg is carrying the session. False in BLE mode and on older daemons.
  final bool bridgeUpgradeCapable;

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
  int _scanGeneration = 0;
  StreamSubscription<BleLinkStatus>? _statusSub;
  AppLifecycleListener? _lifecycle;
  ControllerService? _service;
  Timer? _statsTimer;
  final Map<String, int> _deviceDisconnectGenerations = {};
  int _globalDisconnectGeneration = 0;
  bool _intentionalDisconnect = false;
  int _disconnectEpoch = 0;
  bool _launchAutoConnectStarted = false;
  bool _autoConnectSuppressed = false;
  bool _manualBrowseSuppressed = false;
  bool _disconnectedByUser = false;
  final Set<String> _userDisconnectedDeviceIds = {};

  /// Bridges whose streams were parked for Wi-Fi but whose bonded BLE link is
  /// still up. An explicit Disconnect or Forget drops these too.
  final Set<String> _parkedBleDeviceIds = {};
  final Set<String> _droppedDeviceIds = {};

  final Map<String, int> _reconnectAttempts = {};
  final Set<String> _reconnecting = {};

  WifiLink? _wifiLink;
  BleTransport? _wifiTransport;
  StreamSubscription<BleConnectionState>? _wifiStateSub;
  StreamSubscription<BleScanResult>? _fallbackScanSub;
  StreamSubscription<BleConnectionState>? _bleCompositeStateSub;
  String? _bleCompositeStateId;
  String? _wifiDeviceId;
  BleLinkStatus _lastStatus = const BleLinkStatus(BleLinkPhase.idle);

  /// True between an accepted upgrade request and the daemon reconnecting.
  bool _upgradeAwaitingReconnect = false;
  DateTime? _upgradeReconnectDeadline;
  Timer? _upgradeWatchdog;

  @override
  RealDeviceState build() {
    final transport = ref.watch(realTransportProvider);
    _statusSub = transport.statusChanges.listen(_handleBleLinkStatus);
    _lifecycle?.dispose();
    final lifecycle = _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        unawaited(
          transport.handleAppLifecycle(switch (s) {
            AppLifecycleState.resumed => BleAppLifecycle.resumed,
            AppLifecycleState.inactive => BleAppLifecycle.inactive,
            AppLifecycleState.paused => BleAppLifecycle.paused,
            AppLifecycleState.detached => BleAppLifecycle.detached,
            AppLifecycleState.hidden => BleAppLifecycle.inactive,
          }),
        );
        if (s == AppLifecycleState.resumed) unawaited(_handleAppResume());
      },
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
      _bleCompositeStateSub?.cancel();
      _statsTimer?.cancel();
      _upgradeWatchdog?.cancel();
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

  /// The WebSocket transport behind the current Wi-Fi link, unwrapping the
  /// opt-in TCP/BLE composite. Null in BLE mode or before a Wi-Fi connect.
  WmrWsTransport? get _wsTransport {
    final transport = _wifiTransport;
    if (transport is WmrWsTransport) return transport;
    if (transport is CompositeBleTransport) return transport.tcp;
    return null;
  }

  /// Whether the daemon behind the active Wi-Fi link advertised the root
  /// upgrade unit, and TCP (not the BLE fallback) is carrying it.
  bool _upgradeCapableFor(BridgeTransportKind transport) {
    if (transport != BridgeTransportKind.wifi) return false;
    final id = _wifiDeviceId;
    final ws = _wsTransport;
    if (id == null || ws == null) return false;
    final leg = _wifiLink?.activeLeg;
    if (leg != null && leg() != WifiLinkLeg.tcp) return false;
    return ws.helloFor(id)?.upgradeCapable ?? false;
  }

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
        _droppedDeviceIds.remove(id);
        if (_upgradeAwaitingReconnect && id == _wifiDeviceId) {
          _finishUpgrade(const BridgeUpgradeState.idle());
        }
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
            // Remember it so a resume can redial it even after the campaign
            // exhausts its attempts. A bridge the user disconnected stays out.
            if (!_userDisconnectedDeviceIds.contains(id)) {
              _droppedDeviceIds.add(id);
              _scheduleReconnect(id);
            }
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

  /// Forwards the BLE handoff composite's own connection state for
  /// [deviceId].
  ///
  /// The raw BLE status stream only describes the fallback leg. While TCP
  /// carries the session a radio drop is correctly ignored, and if TCP then
  /// drops too no further raw BLE event arrives; the composite reports that
  /// loss on its own stream, which is the only BLE-mode source that sees both
  /// legs.
  void _watchBleComposite(String deviceId) {
    if (state.activeTransport == BridgeTransportKind.wifi) return;
    if (_bleCompositeStateId == deviceId && _bleCompositeStateSub != null) {
      return;
    }
    unawaited(_bleCompositeStateSub?.cancel());
    _bleCompositeStateId = deviceId;
    _bleCompositeStateSub = _bleHandoffTransport
        .connectionState(deviceId)
        .listen(
          (s) => _onBleCompositeState(deviceId, s),
          onError: (Object _) {},
        );
  }

  void _cancelBleCompositeState([String? deviceId]) {
    if (deviceId != null && _bleCompositeStateId != deviceId) return;
    final sub = _bleCompositeStateSub;
    _bleCompositeStateSub = null;
    _bleCompositeStateId = null;
    unawaited(sub?.cancel());
  }

  void _onBleCompositeState(String id, BleConnectionState s) {
    if (_bleCompositeStateId != id) return;
    if (state.activeTransport == BridgeTransportKind.wifi) return;
    switch (s) {
      case BleConnectionState.connected:
      case BleConnectionState.connecting:
        // The raw BLE stream owns the connect phases and the ready status.
        return;
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
    if (_intentionalDisconnect || _userDisconnectedDeviceIds.contains(id)) {
      return;
    }
    // Both the raw BLE loss and the composite's loss can report the same
    // drop; one pending retry is enough.
    if (_reconnectTimers[id] != null) return;
    _reconnectTimers[id]?.cancel();
    final policy = ref.read(reconnectPolicyProvider);
    final attempt = _reconnectAttempts[id] ?? 0;
    if (_upgradeAwaitingReconnect) {
      final deadline = _upgradeReconnectDeadline;
      if (deadline != null && !DateTime.now().isBefore(deadline)) {
        _finishUpgrade(
          const BridgeUpgradeState(
            BridgeUpgradePhase.failed,
            message: 'The bridge did not come back after the upgrade.',
          ),
        );
        return;
      }
    } else if (attempt >= policy.maxAttempts) {
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
      await _connect(id, userInitiated: false);
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
    BridgeUpgradeState? bridgeUpgrade,
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
      bridgeUpgrade: bridgeUpgrade ?? state.bridgeUpgrade,
      bridgeUpgradeCapable: _upgradeCapableFor(nextTransport),
    );
  }

  /// Failures arrive on the transport's status stream as well, so errors
  /// here only need to be swallowed.
  Future<void> startScan() async {
    _autoConnectSuppressed = true;
    _manualBrowseSuppressed = true;
    await _scanSub?.cancel();
    final generation = ++_scanGeneration;
    _seen.clear();
    _update(results: const []);
    _scanSub = _transport.scan().listen(
      (r) {
        _seen[r.deviceId] = r;
        ref
            .read(bridgeTransportKindsProvider.notifier)
            .set(r.deviceId, state.activeTransport);
        _update(
          results: _seen.values.toList()
            ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999)),
        );
      },
      onError: (Object _) => _endBrowse(generation),
      onDone: () => _endBrowse(generation),
    );
  }

  /// A scan can end without [stopScan]: the transport closes its stream after
  /// its own timeout. The browse is over then too, otherwise a later resume
  /// would stay suppressed until the next explicit user action.
  void _endBrowse(int generation) {
    // A stale stream must not clear the suppression of a newer scan.
    if (generation != _scanGeneration) return;
    _scanSub = null;
    _manualBrowseSuppressed = false;
    if (ref.mounted) _update();
  }

  Future<void> stopScan() async {
    // A screen may be disposed after the provider itself is; there is nothing
    // left to stop and touching state would throw.
    if (!ref.mounted) return;
    final transport = _transport;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await transport.stopScan();
    } catch (_) {
      // A disposed transport has nothing left to stop.
    }
    // The browse is over: it must not keep a later resume from redialling.
    _manualBrowseSuppressed = false;
    if (ref.mounted) _update();
  }

  /// Connects and subscribes. Also the way to reconnect after a lost
  /// connection: it repeats the whole sequence.
  ///
  /// An automatic retry must not clear the records a resume relies on, so the
  /// user-action bookkeeping lives in the [userInitiated] branch.
  Future<void> connect(String deviceId) =>
      _connect(deviceId, userInitiated: true);

  Future<void> _connect(String deviceId, {required bool userInitiated}) async {
    _autoConnectSuppressed = true;
    if (userInitiated) {
      _manualBrowseSuppressed = false;
      _disconnectedByUser = false;
      _userDisconnectedDeviceIds.remove(deviceId);
      _droppedDeviceIds.remove(deviceId);
    }
    if (_connectedDeviceIds.contains(deviceId) ||
        _connectingDeviceIds.contains(deviceId)) {
      return;
    }
    _parkedBleDeviceIds.remove(deviceId);
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
          _reportConnectFailure(deviceId, error);
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
          _reportConnectFailure(deviceId, error);
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
      } else {
        _watchBleComposite(deviceId);
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

  /// Reports a failed dial on whichever transport carries it.
  ///
  /// A failure reaching one of these generic catches used to go through the
  /// Wi-Fi reporter only, which returns early on Bluetooth. The device then
  /// stayed "connecting" with no failure status, so an automatic re-dial was
  /// never scheduled and the retry campaign stalled silently.
  void _reportConnectFailure(String deviceId, Object error) {
    _handleLinkStatus(
      BleLinkStatus(
        BleLinkPhase.connectFailed,
        deviceId: deviceId,
        message: state.activeTransport == BridgeTransportKind.wifi
            ? wifiFailureMessage(error)
            : '$error',
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

  /// Chooses the link the connect screen shows. Switching away from
  /// Bluetooth leaves the bonded BLE link up (only the stream CCCDs are
  /// turned off); switching away from Wi-Fi ends its session.
  Future<void> selectTransport(BridgeTransportKind kind) async {
    _autoConnectSuppressed = true;
    if (state.activeTransport == kind) return;
    await stopScan();
    if (state.activeTransport == BridgeTransportKind.ble) {
      await _releaseBleLink();
    } else {
      await _disconnect(forget: false);
    }
    if (kind == BridgeTransportKind.ble) {
      await _disposeWifiTransport();
    }
    _lastStatus = const BleLinkStatus(BleLinkPhase.idle);
    _update(activeTransport: kind);
  }

  /// Runs one user-requested LAN discovery pass and publishes the results.
  /// Best-effort: no network means an empty list, and a failure is shown in
  /// state rather than thrown at the tap. A manual scan never auto-connects.
  Future<void> discoverLan() async {
    _autoConnectSuppressed = true;
    _manualBrowseSuppressed = true;
    try {
      await _discoverLan();
    } finally {
      // The one-shot pass is over; keep the suppression only for an active
      // browse, not for the rest of the run.
      _manualBrowseSuppressed = false;
    }
  }

  /// Asks the connected Wi-Fi daemon to install its latest release.
  ///
  /// An accepted request restarts the daemon, so the link is expected to
  /// drop; the ordinary reconnect campaign then dials it back. While the
  /// upgrade is pending its retry budget is extended past the usual six
  /// attempts, because a package install takes longer than a transient drop.
  Future<void> requestBridgeUpgrade() async {
    if (state.bridgeUpgrade.isActive) return;
    final id = _wifiDeviceId;
    final ws = _wsTransport;
    if (ws == null || id == null || !state.bridgeUpgradeCapable) {
      _update(
        bridgeUpgrade: const BridgeUpgradeState(
          BridgeUpgradePhase.failed,
          message:
              'This bridge cannot upgrade from the app. '
              'On the Pi, run: $bridgeManualUpgradeCommand',
        ),
      );
      return;
    }
    _update(
      bridgeUpgrade: const BridgeUpgradeState(BridgeUpgradePhase.sending),
    );
    try {
      final status = await ws.requestUpgrade(id);
      switch (status.state) {
        case WmrWsUpgradeState.started:
          _upgradeAwaitingReconnect = true;
          _upgradeReconnectDeadline = DateTime.now().add(
            const Duration(minutes: 5),
          );
          _upgradeWatchdog?.cancel();
          _upgradeWatchdog = Timer(const Duration(minutes: 5), () {
            if (!_upgradeAwaitingReconnect) return;
            _finishUpgrade(
              const BridgeUpgradeState(
                BridgeUpgradePhase.failed,
                message: 'The bridge did not come back after the upgrade.',
              ),
            );
          });
          _reconnectTimers.remove(id)?.cancel();
          _reconnectAttempts.remove(id);
          _reconnecting.remove(id);
          _update(
            bridgeUpgrade: const BridgeUpgradeState(
              BridgeUpgradePhase.restarting,
              message: 'Upgrade started. Waiting for the bridge to restart…',
            ),
          );
        case WmrWsUpgradeState.busy:
          _update(
            bridgeUpgrade: const BridgeUpgradeState(
              BridgeUpgradePhase.busy,
              message: 'Another upgrade is already running on the bridge.',
            ),
          );
        case WmrWsUpgradeState.error:
          _update(
            bridgeUpgrade: BridgeUpgradeState(
              BridgeUpgradePhase.failed,
              message: _upgradeErrorMessage(status.code),
            ),
          );
        case WmrWsUpgradeState.unknown:
          _update(
            bridgeUpgrade: const BridgeUpgradeState(
              BridgeUpgradePhase.failed,
              message: 'The bridge sent an unexpected upgrade reply.',
            ),
          );
      }
    } on WmrWsControlException catch (error) {
      _update(
        bridgeUpgrade: BridgeUpgradeState(
          BridgeUpgradePhase.failed,
          message: _upgradeErrorMessage(error.code),
        ),
      );
    } catch (error) {
      _update(
        bridgeUpgrade: BridgeUpgradeState(
          BridgeUpgradePhase.failed,
          message: 'Upgrade request failed: $error',
        ),
      );
    }
  }

  static String _upgradeErrorMessage(String? code) => switch (code) {
    'auth_failed' =>
      'The bridge has no token configured; '
          'in-app upgrades need one. Add a token on the Pi and reconnect.',
    'unavailable' =>
      'This bridge cannot upgrade itself. '
          'On the Pi, run: $bridgeManualUpgradeCommand',
    _ =>
      'The bridge refused the upgrade'
          '${code == null ? '' : ' ($code)'}.',
  };

  void _finishUpgrade(BridgeUpgradeState next) {
    _upgradeAwaitingReconnect = false;
    _upgradeReconnectDeadline = null;
    _upgradeWatchdog?.cancel();
    _upgradeWatchdog = null;
    if (ref.mounted) _update(bridgeUpgrade: next);
  }

  /// Scans LAN once when the Connect screen opens, then connects to the last
  /// bridge this app used, or to the only bridge discovery found.
  ///
  /// One attempt per app run. Any explicit user action (manual scan, BLE
  /// connect, transport switch or disconnect) suppresses the automatic dial.
  Future<void> launchAutoConnect() async {
    if (_launchAutoConnectStarted) return;
    _launchAutoConnectStarted = true;
    if (!ref.read(launchAutoConnectEnabledProvider)) return;
    if (state.connected ||
        state.busy ||
        state.activeTransport != BridgeTransportKind.ble) {
      return;
    }
    KnownBridge? remembered;
    try {
      remembered = await ref.read(knownBridgeStoreProvider).load();
    } catch (_) {
      // No storage, no remembered bridge: the sole discovered one still works.
    }
    if (!ref.mounted || _autoConnectSuppressed) return;
    final attempted = await _discoverLan(remembered: remembered);
    // A blocked or failing scan must not keep a saved bridge off the wire: the
    // remembered address is the fallback, with `hello` still verifying its id.
    if (!attempted &&
        remembered != null &&
        ref.mounted &&
        !_autoConnectSuppressed) {
      await _autoConnect(const [], remembered);
    }
  }

  /// Gives a dropped link a fresh attempt when the app returns to the
  /// foreground.
  ///
  /// Android can suspend the process while a link is down: the backoff
  /// campaign runs out, or its timer is frozen and fires only after the app
  /// is back. A resume clears the exhausted counters and dials every bridge
  /// that dropped, or repeats remembered-bridge discovery when no bridge was
  /// ever up.
  ///
  /// A bridge the user disconnected by itself stays down, and an explicit
  /// Disconnect of every bridge suppresses the automatic redial until the
  /// user connects again. An active manual scan or LAN discovery also keeps
  /// the automatic dial off while it runs: the user is browsing, not waiting
  /// to reconnect. Both clear that suppression when they finish.
  Future<void> _handleAppResume() async {
    if (state.connected || state.busy || _intentionalDisconnect) return;
    _reconnectAttempts.clear();
    _reconnecting.clear();
    if (_disconnectedByUser || _manualBrowseSuppressed) return;
    _autoConnectSuppressed = false;
    final dropped = _droppedDeviceIds
        .where((id) => !_userDisconnectedDeviceIds.contains(id))
        .toList(growable: false);
    if (dropped.isNotEmpty) {
      for (final id in dropped) {
        _reconnectTimers.remove(id)?.cancel();
      }
      for (final id in dropped) {
        await _connect(id, userInitiated: false);
      }
      return;
    }
    final target = state.deviceId;
    if (target != null) {
      // The remembered primary may itself be the row the user disconnected;
      // do not rediscover and dial it behind their back.
      if (_userDisconnectedDeviceIds.contains(target)) return;
      _reconnectTimers.remove(target)?.cancel();
      await _connect(target, userInitiated: false);
      return;
    }
    await _resumeAutoConnect();
  }

  /// The launch auto-connect runs once per app run, so the resume path repeats
  /// the remembered-bridge lookup here instead of calling it again.
  Future<void> _resumeAutoConnect() async {
    if (state.activeTransport != BridgeTransportKind.ble) return;
    if (!ref.read(launchAutoConnectEnabledProvider)) return;
    KnownBridge? remembered;
    try {
      remembered = await ref.read(knownBridgeStoreProvider).load();
    } catch (_) {
      // No storage, no remembered bridge: the sole discovered one still works.
    }
    if (!ref.mounted || _autoConnectSuppressed) return;
    final attempted = await _discoverLan(remembered: remembered);
    if (!attempted &&
        remembered != null &&
        ref.mounted &&
        !_autoConnectSuppressed) {
      await _autoConnect(const [], remembered);
    }
  }

  /// Runs one discovery pass and dials the remembered or sole bridge.
  ///
  /// Returns true when discovery handed the dial to [_autoConnect] or a pass
  /// is already running, so a caller does not start a second dial against the
  /// same bridge. A failed pass still lets the caller fall back to the
  /// remembered address.
  Future<bool> _discoverLan({KnownBridge? remembered}) async {
    // A resume can land in the middle of the launch pass. Report it as
    // attempted: the running pass owns the dial, and a second `connectWifi`
    // would dispose the transport the first dial is still using.
    if (state.discoveringLan) return true;
    _update(discoveringLan: true, clearLanError: true);
    try {
      final found = _deduplicateLanEndpoints(
        await ref.read(lanDiscoveryProvider)(),
      );
      if (!ref.mounted) return false;
      _update(lanEndpoints: found);
      if (remembered != null || found.length == 1) {
        await _autoConnect(found, remembered);
        return true;
      }
      return false;
    } catch (error) {
      if (ref.mounted) _update(lanError: '$error');
      return false;
    } finally {
      if (ref.mounted) _update(discoveringLan: false);
    }
  }

  /// Discovery already groups one bridge id across interfaces. Grouping here
  /// again keeps the UI and the auto-dial correct for any other source.
  static List<WmrWsEndpoint> _deduplicateLanEndpoints(
    List<WmrWsEndpoint> found,
  ) {
    final groups = <String, WmrWsEndpoint>{};
    for (final endpoint in found) {
      final bridgeId = endpoint.bridgeId;
      final key = bridgeId != null && bridgeId.isNotEmpty
          ? 'bridge:$bridgeId'
          : 'device:${endpoint.resolvedDeviceId}';
      final prior = groups[key];
      groups[key] = prior == null
          ? endpoint
          : prior.withCandidateHosts([
              ...prior.hosts.skip(1),
              ...endpoint.hosts,
            ]);
    }
    return List<WmrWsEndpoint>.unmodifiable(groups.values);
  }

  Future<void> _autoConnect(
    List<WmrWsEndpoint> found,
    KnownBridge? remembered,
  ) async {
    if (_autoConnectSuppressed || state.connected || state.busy) return;
    WmrWsEndpoint? target;
    var bleFallback = true;
    final rememberedId = remembered?.bridgeId;
    if (rememberedId != null && rememberedId.isNotEmpty) {
      for (final endpoint in found) {
        if (endpoint.bridgeId == rememberedId) {
          target = endpoint;
          bleFallback = remembered!.bleFallback;
          break;
        }
      }
    }
    if (target == null && found.length == 1) target = found.single;
    if (target == null &&
        found.isEmpty &&
        remembered != null &&
        remembered.hosts.isNotEmpty) {
      // Discovery can be blocked even when the last bridge is still reachable;
      // the remembered address is the fallback, with the expected bridge id
      // still verified by the transport during `hello`.
      target = WmrWsEndpoint(
        host: remembered.hosts.first,
        candidateHosts: remembered.hosts.skip(1),
        port: remembered.port,
        bridgeId: remembered.bridgeId,
      );
      bleFallback = remembered.bleFallback;
    }
    if (target == null) return;
    try {
      await connectWifi(
        host: target.host,
        port: target.port,
        path: target.path,
        bridgeId: target.bridgeId,
        name: target.name,
        candidateHosts: target.hosts.skip(1),
        secure: target.secure,
        bleFallback: bleFallback,
      );
    } catch (_) {
      // The Wi-Fi panel and the link state report a failed automatic dial.
    }
  }

  /// Connects to a Pi Wi-Fi bridge by host:port, with the optional shared
  /// token. The token is never logged or kept in app state.
  ///
  /// When [token] is empty, the token saved for [bridgeId] or [host] in the
  /// platform secure storage is used. That is how a bridge the app learned
  /// over BLE FF13 still authenticates after a restart with Bluetooth off.
  /// Pass [rememberToken] to save a hand-typed token for next time; it is
  /// written only after the connect succeeds, so a mistyped token is not kept.
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
    bool rememberToken = false,
  }) async {
    final trimmedToken = token?.trim();
    final tokenStore = ref.read(bridgeTokenStoreProvider);
    final savedToken = trimmedToken == null || trimmedToken.isEmpty
        ? await tokenStore.load(bridgeId: bridgeId, host: host.trim())
        : null;
    final effectiveToken = trimmedToken != null && trimmedToken.isNotEmpty
        ? trimmedToken
        : savedToken;
    final endpoint = WmrWsEndpoint(
      host: host.trim(),
      candidateHosts: candidateHosts,
      port: port,
      path: path ?? wmrWsDefaultPath,
      secure: secure,
      bridgeId: bridgeId,
      name: name,
      token: effectiveToken == null || effectiveToken.isEmpty
          ? null
          : effectiveToken,
    );
    final id = endpoint.resolvedDeviceId;

    if (state.activeTransport == BridgeTransportKind.ble) {
      // A Wi-Fi connect must not drop the bonded BLE link: turn the stream
      // CCCDs off and leave the bridge reachable over Bluetooth.
      await _releaseBleLink();
    } else {
      await _disconnect(forget: false);
    }
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
    if (state.connectedDeviceIds.contains(id)) {
      if (rememberToken && trimmedToken != null && trimmedToken.isNotEmpty) {
        await tokenStore.save(
          bridgeId: bridgeId,
          hosts: endpoint.hosts,
          token: trimmedToken,
        );
      }
      await _rememberBridge(
        bridgeId: bridgeId,
        hosts: endpoint.hosts,
        port: endpoint.port,
        bleFallback: bleFallback,
      );
    }
  }

  Future<void> _rememberBridge({
    required String? bridgeId,
    required List<String> hosts,
    required int port,
    required bool bleFallback,
  }) async {
    if (bridgeId == null || bridgeId.isEmpty) return;
    try {
      await ref
          .read(knownBridgeStoreProvider)
          .save(
            KnownBridge(
              bridgeId: bridgeId,
              hosts: hosts,
              port: port,
              bleFallback: bleFallback,
            ),
          );
    } catch (_) {
      // Losing the memory only costs the next launch one tap.
    }
  }

  Future<void> _forgetBridge() async {
    try {
      await ref.read(knownBridgeStoreProvider).clear();
    } catch (_) {
      // Nothing saved, or no storage on this platform.
    }
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

  Future<void> disconnect([String? deviceId]) =>
      _disconnect(deviceId: deviceId);

  /// Ends the Bluetooth session's streams without dropping the BLE link.
  ///
  /// A tab switch or a Wi-Fi connect only turns this client's FF11/FF12/FF14
  /// CCCDs off (through [CompositeBleTransport.suspendBleStreams]) and
  /// stops the controller; the bonded GATT link stays up so the Pi keeps
  /// seeing the phone and a later Bluetooth connect reuses it. Only an
  /// explicit Disconnect or Forget calls [disconnect] and drops the link.
  Future<void> _releaseBleLink() async {
    _finishUpgrade(const BridgeUpgradeState.idle());
    _disconnectedByUser = true;
    _userDisconnectedDeviceIds.clear();
    _droppedDeviceIds.clear();
    _cancelBleCompositeState();
    _globalDisconnectGeneration++;
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    _reconnectAttempts.clear();
    _reconnecting.clear();
    _disconnectEpoch++;

    final transport = _bleHandoffTransport;
    final ids = {..._connectedDeviceIds, ..._connectingDeviceIds};
    if (transport is CompositeBleTransport) {
      for (final id in ids) {
        // Before the service cancels its listeners: afterwards the composite
        // has forgotten which CCCDs this client had enabled.
        await transport.suspendBleStreams(id);
      }
    }
    _parkedBleDeviceIds.addAll(ids);

    _statsTimer?.cancel();
    await _service?.dispose();
    _service = null;
    _connectingDeviceIds.clear();
    _connectedDeviceIds.clear();
    _deviceStatuses.clear();
    _lastStatus = const BleLinkStatus(BleLinkPhase.idle);
  }

  Future<void> _disconnect({String? deviceId, bool forget = true}) async {
    _autoConnectSuppressed = true;
    _finishUpgrade(const BridgeUpgradeState.idle());
    if (deviceId != null) {
      // Only this row stays down; another bridge that later drops must still
      // be redialled on resume.
      _userDisconnectedDeviceIds.add(deviceId);
      _droppedDeviceIds.remove(deviceId);
      _deviceDisconnectGenerations[deviceId] =
          (_deviceDisconnectGenerations[deviceId] ?? 0) + 1;
      _reconnectTimers.remove(deviceId)?.cancel();
      _reconnectAttempts.remove(deviceId);
      _reconnecting.remove(deviceId);
      _disconnectEpoch++;

      _cancelBleCompositeState(deviceId);
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
      if (_parkedBleDeviceIds.remove(deviceId)) {
        // A Wi-Fi switch parked this bridge's stream but left the bond up;
        // an explicit Disconnect is the one place that must drop it.
        try {
          await _bleHandoffTransport.disconnect(deviceId);
        } catch (_) {}
      }
      _update();
      return;
    }

    _disconnectedByUser = true;
    _userDisconnectedDeviceIds.clear();
    _droppedDeviceIds.clear();
    await _stopFallbackScan();
    _cancelBleCompositeState();
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
      if (forget) {
        final parked = _parkedBleDeviceIds.toList();
        _parkedBleDeviceIds.clear();
        for (final id in parked) {
          // The explicit Disconnect or Forget is the one action that drops a
          // link parked for Wi-Fi; a transport switch leaves it up.
          try {
            await _bleHandoffTransport.disconnect(id);
          } catch (_) {}
        }
        await _forgetBridge();
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

/// Whether bridge update checks may offer pre-release builds.
///
/// Stable-only until the saved opt-in says otherwise, so a user who never
/// asked for release candidates is not pushed onto one. The choice is written
/// back on every change and survives a restart.
final bridgeUpdateSettingsProvider =
    NotifierProvider<BridgeUpdateSettings, bool>(BridgeUpdateSettings.new);

class BridgeUpdateSettings extends Notifier<bool> {
  Future<void>? _loading;

  /// Set once the user changes the opt-in, so a slow load cannot overwrite it.
  bool _changed = false;

  @override
  bool build() {
    _loading = _restore();
    return false;
  }

  /// Completes when the saved value has been read and applied.
  Future<void> get ready => _loading ?? Future<void>.value();

  Future<void> _restore() async {
    try {
      final saved = await ref.read(bridgeUpdateSettingsStoreProvider).load();
      if (ref.mounted && saved && !_changed) state = true;
    } catch (_) {
      // No storage, no saved opt-in: stable-only stays.
    }
  }

  /// Applies the opt-in now and saves it for the next launch.
  Future<void> setIncludePreReleases(bool value) async {
    _changed = true;
    state = value;
    try {
      await ref.read(bridgeUpdateSettingsStoreProvider).save(value);
    } catch (_) {
      // The choice still applies to this run.
    }
  }
}

/// The running app's semantic version, parsed from [appVersionProvider].
///
/// Null when the platform version is unknown or not a semantic version, so the
/// app update banner stays silent rather than guessing.
final runningAppVersionProvider = FutureProvider<WmrSemanticVersion?>((
  ref,
) async {
  final text = await ref.watch(appVersionProvider.future);
  return WmrSemanticVersion.tryParse(text);
});

/// Reads wmr-companion GitHub releases for the in-app updater.
final appReleaseCheckerProvider = Provider<AppReleaseChecker>(
  (ref) => AppReleaseChecker(),
);

/// The platform installer behind the app updater channel.
final appInstallerProvider = Provider<AppInstaller>((ref) => AppInstaller());

/// The latest wmr-companion release, null while unknown, offline or
/// unverifiable.
final latestAppReleaseProvider = FutureProvider<AppRelease?>(
  (ref) => ref.watch(appReleaseCheckerProvider).latest(),
);

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  permissionRequired,
  installed,
  failed,
}

/// What the app update banner shows: the result of the automatic or manual
/// check, and the progress of the verified download and install.
class AppUpdateState {
  const AppUpdateState(this.phase, {this.release, this.message});

  const AppUpdateState.idle()
    : phase = AppUpdatePhase.idle,
      release = null,
      message = null;

  final AppUpdatePhase phase;

  /// The release being offered or installed, once one is known.
  final AppRelease? release;

  /// Human-readable result or progress, or null while idle.
  final String? message;

  bool get busy =>
      phase == AppUpdatePhase.checking || phase == AppUpdatePhase.downloading;
}

/// Drives the manual "Check for updates" and the verified APK install.
///
/// The install is fail-closed: [AppReleaseChecker.downloadAndInstall] verifies
/// the SHA-256 digest before the system installer is asked to run, and Android
/// refusing installs from this app sends the user to the unknown-sources
/// settings with the release kept for a retry.
class AppUpdateController extends Notifier<AppUpdateState> {
  @override
  AppUpdateState build() => const AppUpdateState.idle();

  /// Reads the latest release, optionally bypassing this session's cache so a
  /// manual check means a fresh request to GitHub.
  Future<AppRelease?> _fetchLatest({bool fresh = false}) {
    if (fresh) {
      // A new checker drops its cache with the previous provider value.
      ref.invalidate(appReleaseCheckerProvider);
      ref.invalidate(latestAppReleaseProvider);
    }
    return ref.read(latestAppReleaseProvider.future);
  }

  /// Runs one user-requested check and reports the result in [state].
  Future<void> check() async {
    if (state.busy) return;
    final running = await ref.read(runningAppVersionProvider.future);
    if (!ref.mounted) return;
    if (running == null) {
      state = const AppUpdateState(
        AppUpdatePhase.failed,
        message: "Could not read this app's version.",
      );
      return;
    }
    state = const AppUpdateState(AppUpdatePhase.checking);
    final latest = await _fetchLatest(fresh: true);
    if (!ref.mounted) return;
    if (latest == null) {
      state = const AppUpdateState(
        AppUpdatePhase.failed,
        message: 'Could not reach GitHub. Check the network and try again.',
      );
      return;
    }
    state = latest.version.compareTo(running) > 0
        ? AppUpdateState(
            AppUpdatePhase.available,
            release: latest,
            message: 'Version ${latest.version} is available.',
          )
        : AppUpdateState(
            AppUpdatePhase.upToDate,
            message: 'WMR Companion $running is the latest version.',
          );
  }

  /// Set across the whole install, including the awaits before
  /// [AppUpdateState.busy] turns true, so a double tap starts one install.
  bool _installInFlight = false;

  /// Downloads and verifies the newer release, then hands it to the system
  /// installer.
  ///
  /// When Android has not allowed installs from this app, opens that settings
  /// screen instead and keeps the release ready for a retry after the user
  /// returns. Platforms without an installer report that instead of offering
  /// an install that cannot run.
  Future<void> installLatest() async {
    if (state.busy || _installInFlight) return;
    final installer = ref.read(appInstallerProvider);
    if (!installer.supportsSelfInstall) {
      state = const AppUpdateState(
        AppUpdatePhase.failed,
        message: 'In-app update installs are only available on Android.',
      );
      return;
    }
    _installInFlight = true;
    try {
      await _install(installer);
    } finally {
      _installInFlight = false;
    }
  }

  Future<void> _install(AppInstaller installer) async {
    var release = state.release;
    if (release == null) {
      final running = await ref.read(runningAppVersionProvider.future);
      final latest = await _fetchLatest();
      if (!ref.mounted) return;
      if (latest == null ||
          running == null ||
          latest.version.compareTo(running) <= 0) {
        state = const AppUpdateState(
          AppUpdatePhase.failed,
          message: 'No newer release was found.',
        );
        return;
      }
      release = latest;
    }
    if (!await installer.canRequestPackageInstalls()) {
      if (!ref.mounted) return;
      state = AppUpdateState(
        AppUpdatePhase.permissionRequired,
        release: release,
        message:
            'Allow installs from WMR Companion in Settings, '
            'then tap Install again.',
      );
      await _openInstallSettings(installer);
      return;
    }
    state = AppUpdateState(
      AppUpdatePhase.downloading,
      release: release,
      message: 'Downloading and verifying the update…',
    );
    try {
      await ref
          .read(appReleaseCheckerProvider)
          .downloadAndInstall(release, installer.installApk);
      if (!ref.mounted) return;
      state = AppUpdateState(
        AppUpdatePhase.installed,
        release: release,
        message: 'Update installed: WMR Companion ${release.version}.',
      );
    } on AppReleaseException catch (error) {
      if (!ref.mounted) return;
      state = AppUpdateState(
        AppUpdatePhase.failed,
        release: release,
        message: error.message,
      );
    } on PlatformException catch (error) {
      if (!ref.mounted) return;
      if (error.code == 'permission_denied') {
        state = AppUpdateState(
          AppUpdatePhase.permissionRequired,
          release: release,
          message:
              'Allow installs from WMR Companion in Settings, '
              'then tap Install again.',
        );
        await _openInstallSettings(installer);
        return;
      }
      state = AppUpdateState(
        AppUpdatePhase.failed,
        release: release,
        message: error.message ?? 'The install failed (${error.code}).',
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = AppUpdateState(
        AppUpdatePhase.failed,
        release: release,
        message: 'Update failed: $error',
      );
    }
  }

  /// Opens the unknown-sources screen, tolerating a host that cannot show it.
  ///
  /// The banner already states what to allow, so a `settings_unavailable`
  /// platform error must not surface as an unhandled async error.
  Future<void> _openInstallSettings(AppInstaller installer) async {
    try {
      await installer.openUnknownSourcesSettings();
    } on PlatformException {
      // Nothing else to open; the permission-required message stays.
    }
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdateState>(
  AppUpdateController.new,
);
