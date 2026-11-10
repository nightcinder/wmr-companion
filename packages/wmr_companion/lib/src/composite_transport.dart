import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_ws/wmr_ws.dart';

/// Which leg of a [CompositeBleTransport] currently carries a bridge.
enum CompositeLeg { tcp, ble }

/// The lane a bridge is using, as published by
/// [CompositeBleTransport.activeLane].
enum CompositeTransportLane { ble, wifi }

/// A bridge the composite has paired with: the identity and LAN details a host
/// persists so the next connection can go straight to Wi-Fi.
class BridgePairing {
  const BridgePairing({
    required this.bridgeId,
    required this.bleDeviceId,
    required this.hosts,
    required this.port,
    required this.path,
    this.name,
    this.token,
    this.secure = false,
  });

  /// The daemon's stable `bridge_id`.
  final String bridgeId;

  /// The BLE device that supplied the FF16 document, when one was used.
  final String? bleDeviceId;

  /// LAN hosts the bridge reported or that discovery supplied.
  final List<String> hosts;

  final int port;
  final String path;
  final String? name;
  final String? token;
  final bool secure;
}

/// A [BleTransport] that prefers the Pi's WebSocket (TCP) link and falls back
/// to BLE GATT, keeping one logical connection across the switch.
///
/// The primary transport is a [WmrWsTransport] (the Linux/Raspberry Pi daemon
/// on `ws://<host>:8765/wmr`). The fallback is any [BleTransport], normally
/// `UniversalBleTransport` from `wmr_ble`. A bridge is dialled over TCP when
/// an endpoint is known, either because the caller configured/discovered one
/// or because the FF16 endpoint document was read over BLE. When TCP cannot
/// connect, or drops later, the same bridge is dialled over BLE GATT. While
/// the bridge is on BLE, [upgradeInterval] retries TCP; an FF16/FF13 read that
/// supplies a LAN endpoint tries immediately, and when TCP succeeds the
/// notification subscriptions move to TCP without being closed.
///
/// Bridges are identified by the daemon's stable `bridge_id` once a hello or
/// an FF16 endpoint document has supplied it. Two scan results that resolve
/// to the same id are published once by [scan]. Before an id has been learned,
/// a BLE result and a TCP result cannot be matched, so both are published.
/// An unauthenticated discovery tile is withheld: it cannot connect without a
/// token, so its host is indexed by `bridge_id` for the FF16 read instead. A
/// bridge seeded with [seedPairedBridge] carries its stored token and is
/// deduplicated against the BLE hit.
///
/// ## BLE radio use
///
/// Following the per-client CCCD rule, the composite turns its own BLE
/// notifications off when TCP becomes active. It writes 0x0000 only to the
/// characteristics it had enabled; it never asks the bridge to silence other
/// clients.
///
/// ## Clock
///
/// [clock] is the TCP transport's clock. BLE notifications are re-stamped
/// onto it as the composite receives them, so a failover does not move the
/// timeline seen by `ControllerService`.
class CompositeBleTransport implements BleTransport {
  CompositeBleTransport({
    required this.tcp,
    required this.ble,
    this.upgradeInterval = const Duration(seconds: 2),
    this.bleScanWait = const Duration(seconds: 5),
    this.onBridgePaired,
  }) : clock = tcp.clock;

  /// Primary WebSocket transport.
  final WmrWsTransport tcp;

  /// Fallback GATT transport.
  ///
  /// The parameter is a [BleTransport] rather than a concrete
  /// `UniversalBleTransport` so this package stays pure Dart; a Flutter host
  /// passes `UniversalBleTransport` from `wmr_ble`.
  final BleTransport ble;

  @override
  final MonotonicClock clock;

  /// How often a bridge on BLE is probed for a working TCP endpoint. A
  /// non-positive duration disables the automatic upgrade.
  final Duration upgradeInterval;

  /// How long [connect] waits for a BLE scan hit when every TCP candidate
  /// failed while a [scan] is still running. Zero disables the wait.
  ///
  /// Without this, a TCP refusal that returns faster than the radio scan can
  /// leave the BLE leg with no candidate, so the failover never happens.
  final Duration bleScanWait;

  /// Called when a bridge's pairing details are known: after an FF16 endpoint
  /// document and its FF13 token are read over BLE, or after a manual Wi-Fi
  /// handshake reports a `bridge_id`.
  ///
  /// A host persists [BridgePairing] so a later start can seed
  /// [seedPairedBridge] and connect to Wi-Fi without asking for a token.
  final void Function(BridgePairing pairing)? onBridgePaired;

  final Map<String, _Route> _routes = {};
  final Map<String, String> _bridgeIds = {};
  final Map<String, _ScanHit> _scanHits = {};
  final Map<String, WmrWsEndpoint> _lanByBridgeId = {};
  final Map<String, String> _pairedTokens = {};
  final Map<String, Set<String>> _pairedTcpCandidates = {};
  final Map<String, bool> _pairedSecure = {};
  final Set<String> _pairedBridgeIds = {};
  final Set<int> _pairedSignatures = {};
  bool _disposed = false;
  bool _scanning = false;
  Completer<void>? _scanWake;

  /// The stable bridge id learned for [deviceId], when one is known.
  ///
  /// [deviceId] may be a TCP endpoint id (`host:port`) or a BLE device id.
  String? bridgeIdFor(String deviceId) => _bridgeIdForDevice(deviceId);

  /// Which leg currently carries [deviceId], or null when the bridge is not
  /// connected.
  ///
  /// A leg switch keeps the connection state `connected`, so a host that
  /// shows the active leg should sample this instead of waiting for a state
  /// change.
  CompositeLeg? activeLegFor(String deviceId) =>
      switch (_routes[deviceId]?.active) {
        _Lane.tcp => CompositeLeg.tcp,
        _Lane.ble => CompositeLeg.ble,
        null => null,
      };

  /// The lane [deviceId] is on now and every lane change after that.
  ///
  /// The first event is the current lane, when the bridge is connected. The
  /// stream stays open across a leg switch; it does not close on a transient
  /// reconnect.
  Stream<CompositeTransportLane> activeLane(String deviceId) async* {
    _ensureUsable();
    final route = _ensureRoute(deviceId);
    final current = _laneOf(route.active);
    if (current != null) yield current;
    yield* route.lanes.stream;
  }

  /// Seeds a bridge the host paired before this transport existed.
  ///
  /// [bridgeId] and [token] are registered on [tcp] so a matching
  /// [WmrWsDiscovery] hit authenticates even on a new DHCP address. Each
  /// stored host becomes a connectable TCP candidate, and [bleDeviceId] is
  /// mapped to [bridgeId] so a BLE scan result and a LAN result share one
  /// bridge entry instead of becoming two tiles.
  void seedPairedBridge({
    required String bridgeId,
    String? bleDeviceId,
    String? name,
    List<String> hosts = const [],
    int port = wmrWsDefaultPort,
    String path = wmrWsDefaultPath,
    String? token,
    bool secure = false,
  }) {
    _ensureUsable();
    final id = bridgeId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(bridgeId, 'bridgeId', 'must not be empty');
    }
    _pairedBridgeIds.add(id);
    _pairedSecure[id] = secure;
    if (token != null && token.isNotEmpty) _pairedTokens[id] = token;
    tcp.registerBridgeToken(id, token);

    final bleId = bleDeviceId?.trim();
    if (bleId != null && bleId.isNotEmpty) {
      _bridgeIds[bleId] = id;
      for (final route in _routes.values) {
        if (route.deviceId == bleId || route.bleDeviceId == bleId) {
          route.bridgeId ??= id;
        }
      }
    }

    final candidates = _pairedTcpCandidates.putIfAbsent(id, () => <String>{});
    for (final host in hosts) {
      final trimmed = host.trim();
      if (trimmed.isEmpty) continue;
      final endpoint = WmrWsEndpoint(
        host: trimmed,
        port: port,
        path: path,
        name: name,
        token: token,
        secure: secure,
        bridgeId: id,
      );
      final tcpId = endpoint.resolvedDeviceId;
      tcp.registerEndpoint(endpoint);
      _bridgeIds[tcpId] = id;
      _lanByBridgeId.putIfAbsent(id, () => endpoint);
      candidates.add(tcpId);
    }
  }

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) {
    _ensureUsable();
    late final StreamController<BleScanResult> controller;
    final subscriptions = <StreamSubscription<BleScanResult>>[];
    final seenIds = <String>{};
    final seenBridgeIds = <String>{};
    var sourcesDone = 0;

    void add(BleScanResult result, {required bool fromBle}) {
      _scanHits[result.deviceId] = _ScanHit(result, fromBle: fromBle);
      if (fromBle) _wakeScanWaiters();
      if (!fromBle) {
        final endpoint = tcp.endpointFor(result.deviceId);
        final bridgeId = endpoint?.bridgeId;
        if (endpoint != null && bridgeId != null && bridgeId.isNotEmpty) {
          if (tcp.isDiscoveredDevice(result.deviceId)) {
            _bridgeIds[result.deviceId] = bridgeId;
            // Keep the live address even when the tile is suppressed, so an
            // FF16 read can merge this host with the bridge's own list.
            _lanByBridgeId[bridgeId] = endpoint;
            final unauthenticated = endpoint.token == null;
            if (unauthenticated && !_pairedBridgeIds.contains(bridgeId)) {
              // A discovery reply never carries the token, so this tile
              // cannot connect. The BLE entry is the first-contact tile.
              return;
            }
          }
        }
      }
      final bridgeId = _bridgeIdForDevice(result.deviceId);
      if (bridgeId != null && !seenBridgeIds.add(bridgeId)) return;
      if (!seenIds.add(result.deviceId)) return;
      if (!controller.isClosed) controller.add(result);
    }

    void done() {
      sourcesDone++;
      if (sourcesDone == 2) {
        _scanning = false;
        _wakeScanWaiters();
        if (!controller.isClosed) unawaited(controller.close());
      }
    }

    void failed(Object error, StackTrace stackTrace) {
      if (!controller.isClosed) controller.addError(error, stackTrace);
    }

    controller = StreamController<BleScanResult>(
      onListen: () {
        _scanning = true;
        try {
          subscriptions.add(
            tcp
                .scan(withServices: withServices)
                .listen(
                  (result) => add(result, fromBle: false),
                  onError: failed,
                  onDone: done,
                ),
          );
        } catch (error, stackTrace) {
          failed(error, stackTrace);
          done();
        }
        try {
          subscriptions.add(
            ble
                .scan(withServices: withServices)
                .listen(
                  (result) => add(result, fromBle: true),
                  onError: failed,
                  onDone: done,
                ),
          );
        } catch (error, stackTrace) {
          failed(error, stackTrace);
          done();
        }
      },
      onCancel: () async {
        _scanning = false;
        _wakeScanWaiters();
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    _ensureUsable();
    _scanning = false;
    _wakeScanWaiters();
    await tcp.stopScan();
    await ble.stopScan();
  }

  @override
  Future<void> connect(String deviceId) async {
    _ensureUsable();
    final route = _ensureRoute(deviceId);
    if (route.state == BleConnectionState.connected) return;
    if (route.switching) return;
    route.intentional = false;
    route.switching = true;
    _setState(route, BleConnectionState.connecting);
    Object? tcpError;
    Object? bleError;
    try {
      final tcpCandidates = _tcpCandidatesFor(route, deviceId);
      if (tcpCandidates.isNotEmpty) {
        route.tcpCandidates.addAll(tcpCandidates);
        try {
          final id = await _tryTcp(route, tcpCandidates);
          if (id != null) {
            await _activateTcp(route, id);
            return;
          }
        } catch (error) {
          tcpError = error;
        }
      }

      var bleCandidates = _bleCandidatesFor(
        route,
        deviceId,
        allowDeviceId: tcpCandidates.isEmpty,
      );
      if (bleCandidates.isEmpty &&
          tcpCandidates.isNotEmpty &&
          _scanning &&
          bleScanWait > Duration.zero) {
        // The scan may still be running: a fast TCP refusal can beat the
        // radio, and without a candidate the failover is impossible.
        await _awaitBleScanHit(bleScanWait);
        bleCandidates = _bleCandidatesFor(
          route,
          deviceId,
          allowDeviceId: false,
        );
      }
      final requireIdentity =
          route.bridgeId != null && bleCandidates.length > 1;
      for (final bleId in bleCandidates) {
        try {
          await _connectBle(route, bleId, requireIdentity: requireIdentity);
          await _activateBle(route);
          return;
        } catch (error) {
          bleError = error;
        }
      }
    } finally {
      route.switching = false;
    }

    _setState(route, BleConnectionState.disconnected);
    throw tcpError ?? bleError ?? StateError('No transport for $deviceId');
  }

  @override
  Future<void> disconnect(String deviceId) async {
    final route = _routes.remove(deviceId);
    if (route == null) return;
    route.intentional = true;
    try {
      _stopUpgrade(route);
      await route.tcpStateSub?.cancel();
      await route.bleStateSub?.cancel();
      route.tcpStateSub = null;
      route.bleStateSub = null;
      await _disableBleNotifications(route);

      final channels = List<_Channel>.of(route.channels);
      route.channels.clear();
      for (final channel in channels) {
        await channel.close();
      }

      final tcpId = route.tcpDeviceId;
      final bleId = route.bleDeviceId;
      if (tcpId != null) {
        try {
          await tcp.disconnect(tcpId);
        } catch (_) {
          // A link that already dropped needs no further teardown.
        }
      }
      if (bleId != null) {
        try {
          await ble.disconnect(bleId);
        } catch (_) {
          // See above.
        }
      }
      route.active = null;
      _setState(route, BleConnectionState.disconnected);
    } finally {
      route.intentional = false;
      if (!route.states.isClosed) await route.states.close();
      if (!route.lanes.isClosed) await route.lanes.close();
    }
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    if (_disposed) {
      yield BleConnectionState.disconnected;
      return;
    }
    final route = _ensureRoute(deviceId);
    yield route.state;
    yield* route.states.stream;
  }

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) {
    final active = _requireActive(deviceId);
    return active.transport.discoverServices(active.deviceId);
  }

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final route = _routes[deviceId];
    if (route == null || route.active == null) {
      throw StateError('Device $deviceId is not connected');
    }
    final channel = _Channel(
      route,
      serviceUuid.toLowerCase(),
      characteristicUuid.toLowerCase(),
    );
    route.channels.add(channel);
    return channel.stream;
  }

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final active = _requireActive(deviceId);
    return active.transport.unsubscribe(
      active.deviceId,
      serviceUuid,
      characteristicUuid,
    );
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final active = _requireActive(deviceId);
    return active.transport.read(
      active.deviceId,
      serviceUuid,
      characteristicUuid,
    );
  }

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) {
    final active = _requireActive(deviceId);
    return active.transport.write(
      active.deviceId,
      serviceUuid,
      characteristicUuid,
      value,
      withoutResponse: withoutResponse,
    );
  }

  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) {
    final active = _requireActive(deviceId);
    return active.transport.connectionInfo(active.deviceId);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final routes = _routes.values.toList();
    _routes.clear();
    for (final route in routes) {
      route.intentional = true;
      _stopUpgrade(route);
      await route.tcpStateSub?.cancel();
      await route.bleStateSub?.cancel();
      await _disableBleNotifications(route);
      final channels = List<_Channel>.of(route.channels);
      route.channels.clear();
      for (final channel in channels) {
        await channel.close();
      }
      final tcpId = route.tcpDeviceId;
      final bleId = route.bleDeviceId;
      if (tcpId != null) {
        try {
          await tcp.disconnect(tcpId);
        } catch (_) {}
      }
      if (bleId != null) {
        try {
          await ble.disconnect(bleId);
        } catch (_) {}
      }
      if (!route.states.isClosed) await route.states.close();
      if (!route.lanes.isClosed) await route.lanes.close();
    }
    await tcp.dispose();
    await ble.dispose();
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('CompositeBleTransport is disposed');
  }

  _Route _ensureRoute(String deviceId) {
    final route = _routes.putIfAbsent(
      deviceId,
      () => _Route(deviceId, tcp, ble, clock),
    );
    route.bridgeId ??= _bridgeIds[deviceId];
    return route;
  }

  ({BleTransport transport, String deviceId}) _requireActive(String deviceId) {
    final route = _routes[deviceId];
    final lane = route?.active;
    final activeId = route?.deviceIdFor(lane);
    final transport = route?.transportFor(lane);
    if (route == null ||
        lane == null ||
        activeId == null ||
        transport == null) {
      throw StateError('Device $deviceId is not connected');
    }
    return (transport: transport, deviceId: activeId);
  }

  List<String> _tcpCandidatesFor(_Route route, String deviceId) {
    final ids = <String>{};
    final current = route.tcpDeviceId;
    if (current != null) ids.add(current);
    ids.addAll(route.tcpCandidates);
    final bridgeId = route.bridgeId;
    if (bridgeId != null) {
      ids.addAll(_pairedTcpCandidates[bridgeId] ?? const <String>{});
    }
    if (tcp.endpointFor(deviceId) != null) ids.add(deviceId);
    return ids.toList();
  }

  Future<String?> _tryTcp(_Route route, List<String> candidates) async {
    if (candidates.isEmpty) return null;
    Object? lastError;
    for (final id in candidates) {
      route.tcpCandidates.add(id);
      try {
        await tcp.connect(id);
        route.tcpDeviceId = id;
        _rememberBridge(route, tcp.helloFor(id)?.bridgeId);
        return id;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('No TCP endpoint answered');
  }

  List<String> _bleCandidatesFor(
    _Route route,
    String deviceId, {
    required bool allowDeviceId,
  }) {
    final candidates = <String>[];
    void add(String id) {
      if (candidates.contains(id) || _claimedByOtherRoute(id, route)) return;
      candidates.add(id);
    }

    final current = route.bleDeviceId;
    if (current != null) {
      candidates.add(current);
      return candidates;
    }
    if (allowDeviceId) add(deviceId);
    final hits = _scanHits.values.where((hit) => hit.fromBle).toList()
      ..sort(
        (a, b) => (b.result.rssi ?? -1000).compareTo(a.result.rssi ?? -1000),
      );
    for (final hit in hits) {
      add(hit.result.deviceId);
    }
    return candidates;
  }

  bool _claimedByOtherRoute(String deviceId, _Route route) =>
      _routes.values.any(
        (other) =>
            !identical(other, route) &&
            (other.deviceId == deviceId ||
                other.bleDeviceId == deviceId ||
                other.tcpDeviceId == deviceId),
      );

  Future<void> _connectBle(
    _Route route,
    String bleId, {
    bool requireIdentity = false,
  }) async {
    route.bleDeviceId = bleId;
    // Some stacks refuse a GATT connect while a scan is running. The hits
    // already seen stay in `_scanHits`.
    await ble.stopScan();
    final state = await ble.connectionState(bleId).first;
    if (state != BleConnectionState.connected) {
      await ble.connect(bleId);
    }
    final endpoint = await _readBleEndpoint(bleId);
    final knownId = route.bridgeId;
    if (knownId != null) {
      if (endpoint != null && endpoint.bridgeId != knownId) {
        await _rejectBle(route);
        throw StateError(
          'BLE device $bleId is bridge ${endpoint.bridgeId}, expected $knownId',
        );
      }
      if (endpoint == null && requireIdentity) {
        await _rejectBle(route);
        throw StateError(
          'BLE device $bleId did not identify its bridge; refusing to switch',
        );
      }
    }
    _watchBle(route);
    if (endpoint != null) {
      await _learnBleEndpoint(route, endpoint);
    } else {
      _startUpgrade(route);
    }
  }

  Future<void> _rejectBle(_Route route) async {
    await route.bleStateSub?.cancel();
    route.bleStateSub = null;
    route.bleStateId = null;
    final bleId = route.bleDeviceId;
    route.bleDeviceId = null;
    if (bleId == null) return;
    try {
      await ble.disconnect(bleId);
    } catch (_) {
      // The failed probe needs no further teardown.
    }
  }

  Future<void> _activateTcp(_Route route, String tcpId) async {
    route.tcpDeviceId = tcpId;
    _rememberBridge(route, tcp.helloFor(tcpId)?.bridgeId);
    _watchTcp(route);
    await _switchChannels(route, _Lane.tcp);
    _stopUpgrade(route);
    _setState(route, BleConnectionState.connected);
    final bridgeId = route.bridgeId;
    // A direct Wi-Fi handshake is a pairing too. Skip it when this activation
    // came from a BLE session: `_learnBleEndpoint` already reported the
    // richer FF16 record.
    if (bridgeId != null && route.bleDeviceId == null) {
      final endpoint = tcp.endpointFor(tcpId);
      _notifyPaired(
        route,
        bridgeId: bridgeId,
        hosts: endpoint == null ? const [] : [endpoint.host],
        port: endpoint?.port ?? wmrWsDefaultPort,
        path: endpoint?.path ?? wmrWsDefaultPath,
        name: endpoint?.name,
        token: endpoint?.token,
        secure: endpoint?.secure ?? false,
      );
    }
  }

  Future<void> _activateBle(_Route route) async {
    _watchBle(route);
    await _switchChannels(route, _Lane.ble);
    _startUpgrade(route);
    _setState(route, BleConnectionState.connected);
    if (route.upgradeImmediately) {
      route.upgradeImmediately = false;
      // FF16/FF13 supplied a live LAN candidate: dial it now, not one timer
      // tick later. A zero interval still means "no automatic upgrade".
      if (upgradeInterval > Duration.zero) {
        unawaited(_attemptUpgrade(route));
      }
    }
  }

  Future<void> _switchChannels(_Route route, _Lane to) async {
    final currentId = route.deviceIdFor(route.active);
    final nextId = route.deviceIdFor(to);
    if (route.active == to && currentId == nextId) return;

    final live = route.channels.where((channel) => channel.isLive).toList();
    if (to == _Lane.tcp) {
      await _disableBleNotifications(route);
    }
    for (final channel in live) {
      await channel.detach();
    }
    route.active = to;
    final lane = _laneOf(to);
    if (lane != null && !route.lanes.isClosed) route.lanes.add(lane);
    for (final channel in live) {
      channel.attach();
    }
  }

  Future<void> _disableBleNotifications(_Route route) async {
    final bleId = route.bleDeviceId;
    final keys = route.bleRefs.keys.toList();
    route.bleRefs.clear();
    if (bleId == null) return;
    for (final key in keys) {
      final separator = key.indexOf('|');
      if (separator < 0) continue;
      final service = key.substring(0, separator);
      final characteristic = key.substring(separator + 1);
      try {
        await ble.unsubscribe(bleId, service, characteristic);
      } catch (_) {
        // The BLE link may already be gone; its CCC went with it.
      }
    }
  }

  void _watchTcp(_Route route) {
    final id = route.tcpDeviceId;
    if (id == null) return;
    if (route.tcpStateSub != null && route.tcpStateId == id) return;
    unawaited(route.tcpStateSub?.cancel());
    route.tcpStateId = id;
    route.tcpStateSub = tcp.connectionState(id).listen((state) {
      if (_disposed || route.intentional) return;
      if (state == BleConnectionState.disconnected &&
          route.active == _Lane.tcp) {
        unawaited(_fallbackToBle(route));
      }
    }, onError: (Object _) {});
  }

  void _watchBle(_Route route) {
    final id = route.bleDeviceId;
    if (id == null) return;
    if (route.bleStateSub != null && route.bleStateId == id) return;
    unawaited(route.bleStateSub?.cancel());
    route.bleStateId = id;
    route.bleStateSub = ble.connectionState(id).listen((state) {
      if (_disposed || route.intentional) return;
      if (state == BleConnectionState.disconnected &&
          route.active == _Lane.ble) {
        unawaited(_recoverFromBleDrop(route));
      }
    }, onError: (Object _) {});
  }

  Future<void> _fallbackToBle(_Route route) async {
    if (_disposed || route.intentional || route.switching) return;
    route.switching = true;
    try {
      final bleCandidates = _bleCandidatesFor(
        route,
        route.deviceId,
        allowDeviceId: false,
      );
      final requireIdentity =
          route.bridgeId != null && bleCandidates.length > 1;
      for (final bleId in bleCandidates) {
        try {
          await _connectBle(route, bleId, requireIdentity: requireIdentity);
          await _activateBle(route);
          return;
        } catch (_) {
          // Try the next scanned bridge before giving up the session.
        }
      }
      await _lose(route);
    } finally {
      route.switching = false;
    }
  }

  Future<void> _recoverFromBleDrop(_Route route) async {
    if (_disposed || route.intentional || route.switching) return;
    route.switching = true;
    try {
      if (route.tcpCandidates.isNotEmpty) {
        try {
          final id = await _tryTcp(route, route.tcpCandidates.toList());
          if (id != null) {
            await _activateTcp(route, id);
            return;
          }
        } catch (_) {
          // Both paths are down; report the loss below.
        }
      }
      await _lose(route);
    } finally {
      route.switching = false;
    }
  }

  Future<void> _lose(_Route route) async {
    _stopUpgrade(route);
    await route.tcpStateSub?.cancel();
    await route.bleStateSub?.cancel();
    route.tcpStateSub = null;
    route.bleStateSub = null;
    final channels = List<_Channel>.of(route.channels);
    for (final channel in channels) {
      await channel.detach();
    }
    route.active = null;
    if (!_disposed) _setState(route, BleConnectionState.disconnected);
  }

  Future<void> _attemptUpgrade(_Route route) async {
    if (_disposed || route.intentional || route.upgrading) return;
    if (route.active != _Lane.ble || route.tcpCandidates.isEmpty) return;
    route.upgrading = true;
    try {
      final id = await _tryTcp(route, route.tcpCandidates.toList());
      if (id != null) await _activateTcp(route, id);
    } catch (_) {
      // Stay on BLE; the next tick retries.
    } finally {
      route.upgrading = false;
    }
  }

  void _startUpgrade(_Route route) {
    if (_disposed ||
        upgradeInterval <= Duration.zero ||
        route.tcpCandidates.isEmpty) {
      return;
    }
    route.upgradeTimer ??= Timer.periodic(upgradeInterval, (_) {
      unawaited(_attemptUpgrade(route));
    });
  }

  void _stopUpgrade(_Route route) {
    route.upgradeTimer?.cancel();
    route.upgradeTimer = null;
  }

  Future<_LanEndpoint?> _readBleEndpoint(String bleId) async {
    try {
      final value = await ble.read(
        bleId,
        wmrBridgeServiceUuid,
        wmrBridgeVersionCharUuid,
      );
      return _LanEndpoint.parse(value);
    } catch (_) {
      // FF16 is a plain version string on older bridges, not this document.
      return null;
    }
  }

  Future<void> _learnBleEndpoint(_Route route, _LanEndpoint endpoint) async {
    final bleId = route.bleDeviceId;
    if (bleId == null) return;
    _rememberBridge(route, endpoint.bridgeId);

    var token = _pairedTokens[endpoint.bridgeId];
    if (endpoint.authRequired) {
      token = await _readBleToken(bleId) ?? token;
      if (token == null) return;
    }

    // Merge hosts the bridge reported with a LAN reply that discovery indexed
    // for the same bridge id: DHCP may have moved the bridge since it wrote
    // its FF16 document.
    final hosts = <String>{...endpoint.hosts};
    final discovered = _lanByBridgeId[endpoint.bridgeId];
    if (discovered != null) hosts.add(discovered.host);

    for (final host in hosts) {
      final candidate = WmrWsEndpoint(
        host: host,
        port: endpoint.port,
        path: endpoint.path,
        name: endpoint.name,
        bridgeId: endpoint.bridgeId,
        token: token,
        secure: _pairedSecure[endpoint.bridgeId] ?? false,
      );
      tcp.registerEndpoint(candidate);
      route.tcpCandidates.add(candidate.resolvedDeviceId);
    }
    if (token != null) tcp.registerBridgeToken(endpoint.bridgeId, token);
    route.upgradeImmediately = true;
    _startUpgrade(route);
    _notifyPaired(
      route,
      bridgeId: endpoint.bridgeId,
      hosts: hosts.toList(),
      port: endpoint.port,
      path: endpoint.path,
      name: endpoint.name,
      token: token,
      secure: _pairedSecure[endpoint.bridgeId] ?? false,
    );
  }

  void _notifyPaired(
    _Route route, {
    required String bridgeId,
    required List<String> hosts,
    required int port,
    required String path,
    String? name,
    String? token,
    bool secure = false,
  }) {
    final callback = onBridgePaired;
    if (callback == null) return;
    final signature = Object.hash(
      bridgeId,
      route.bleDeviceId,
      Object.hashAll(hosts),
      port,
      path,
      name,
      token,
      secure,
    );
    if (!_pairedSignatures.add(signature)) return;
    try {
      callback(
        BridgePairing(
          bridgeId: bridgeId,
          bleDeviceId: route.bleDeviceId,
          hosts: List.unmodifiable(hosts),
          port: port,
          path: path,
          name: name,
          token: token,
          secure: secure,
        ),
      );
    } catch (_) {
      // Host persistence is not the link's concern; a failed save must not
      // turn a working BLE or Wi-Fi connection into a connect error.
    }
  }

  Future<String?> _readBleToken(String bleId) async {
    try {
      final value = await ble.read(
        bleId,
        wmrBridgeServiceUuid,
        wmrBridgeConfigCharUuid,
      );
      final decoded = jsonDecode(utf8.decode(value));
      if (decoded is Map && decoded['type'] == 'wmr_ble_session') {
        final token = decoded['token'];
        if (token is String && token.isNotEmpty) return token;
      }
    } catch (_) {
      // FF13 may be absent, or still hold a calibration window.
    }
    return null;
  }

  void _rememberBridge(_Route route, String? bridgeId) {
    if (bridgeId == null || bridgeId.isEmpty) return;
    final known = route.bridgeId;
    if (known != null && known != bridgeId) return;
    route.bridgeId = bridgeId;
    _bridgeIds[route.deviceId] = bridgeId;
    final tcpId = route.tcpDeviceId;
    if (tcpId != null) _bridgeIds[tcpId] = bridgeId;
    final bleId = route.bleDeviceId;
    if (bleId != null) _bridgeIds[bleId] = bridgeId;
  }

  String? _bridgeIdForDevice(String deviceId) =>
      _bridgeIds[deviceId] ?? _routes[deviceId]?.bridgeId;

  static CompositeTransportLane? _laneOf(_Lane? lane) => switch (lane) {
    _Lane.tcp => CompositeTransportLane.wifi,
    _Lane.ble => CompositeTransportLane.ble,
    null => null,
  };

  /// Wakes [connect] waiters: a BLE hit arrived or the scan stopped.
  void _wakeScanWaiters() {
    final wake = _scanWake;
    _scanWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _awaitBleScanHit(Duration timeout) async {
    final wake = _scanWake ??= Completer<void>();
    try {
      await wake.future.timeout(timeout);
    } on TimeoutException {
      // No BLE bridge advertised in time; the caller reports the TCP error.
    } finally {
      if (identical(_scanWake, wake)) _scanWake = null;
    }
  }

  void _setState(_Route route, BleConnectionState state) {
    if (route.state == state) return;
    route.state = state;
    if (!route.states.isClosed) route.states.add(state);
  }
}

enum _Lane { tcp, ble }

class _Route {
  _Route(this.deviceId, this.tcp, this.ble, this.clock);

  final String deviceId;
  final WmrWsTransport tcp;
  final BleTransport ble;
  final MonotonicClock clock;
  final StreamController<BleConnectionState> states =
      StreamController.broadcast();
  final StreamController<CompositeTransportLane> lanes =
      StreamController.broadcast();
  final List<_Channel> channels = [];
  final Map<String, int> bleRefs = {};

  String? bridgeId;
  String? bleDeviceId;
  String? tcpDeviceId;
  final Set<String> tcpCandidates = {};
  _Lane? active;
  BleConnectionState state = BleConnectionState.disconnected;
  bool intentional = false;
  bool switching = false;
  bool upgrading = false;
  bool upgradeImmediately = false;
  StreamSubscription<BleConnectionState>? tcpStateSub;
  StreamSubscription<BleConnectionState>? bleStateSub;
  String? tcpStateId;
  String? bleStateId;
  Timer? upgradeTimer;

  BleTransport? transportFor(_Lane? lane) => switch (lane) {
    _Lane.tcp => tcp,
    _Lane.ble => ble,
    null => null,
  };

  String? deviceIdFor(_Lane? lane) => switch (lane) {
    _Lane.tcp => tcpDeviceId,
    _Lane.ble => bleDeviceId,
    null => null,
  };

  void addBleRef(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid|$characteristicUuid';
    bleRefs[key] = (bleRefs[key] ?? 0) + 1;
  }

  void removeBleRef(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid|$characteristicUuid';
    final remaining = (bleRefs[key] ?? 0) - 1;
    if (remaining <= 0) {
      bleRefs.remove(key);
    } else {
      bleRefs[key] = remaining;
    }
  }
}

class _Channel {
  _Channel(this.route, this.serviceUuid, this.characteristicUuid);

  final _Route route;
  final String serviceUuid;
  final String characteristicUuid;
  StreamSubscription<BleNotification>? _subscription;

  late final StreamController<BleNotification> _controller =
      StreamController<BleNotification>.broadcast(
        onListen: attach,
        onCancel: () {
          route.channels.remove(this);
          unawaited(detach());
        },
      );

  Stream<BleNotification> get stream => _controller.stream;

  bool get isLive => _controller.hasListener && !_controller.isClosed;

  void attach() {
    if (_subscription != null) return;
    final lane = route.active;
    final transport = route.transportFor(lane);
    final deviceId = route.deviceIdFor(lane);
    if (lane == null || transport == null || deviceId == null) return;
    try {
      _subscription = transport
          .subscribe(deviceId, serviceUuid, characteristicUuid)
          .listen(
            (notification) {
              if (_controller.isClosed) return;
              _controller.add(
                lane == _Lane.ble
                    ? BleNotification(
                        value: notification.value,
                        receivedAtUs: route.clock.nowUs,
                      )
                    : notification,
              );
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!_controller.isClosed) {
                _controller.addError(error, stackTrace);
              }
            },
          );
      if (lane == _Lane.ble) {
        route.addBleRef(serviceUuid, characteristicUuid);
      }
    } catch (error, stackTrace) {
      if (!_controller.isClosed) _controller.addError(error, stackTrace);
    }
  }

  Future<void> detach() async {
    final subscription = _subscription;
    _subscription = null;
    if (route.active == _Lane.ble) {
      route.removeBleRef(serviceUuid, characteristicUuid);
    }
    await subscription?.cancel();
  }

  Future<void> close() async {
    await detach();
    if (!_controller.isClosed) await _controller.close();
  }
}

class _ScanHit {
  const _ScanHit(this.result, {required this.fromBle});

  final BleScanResult result;
  final bool fromBle;
}

class _LanEndpoint {
  const _LanEndpoint({
    required this.bridgeId,
    required this.hosts,
    required this.port,
    required this.path,
    this.name,
    this.authRequired = false,
  });

  final String bridgeId;
  final List<String> hosts;
  final int port;
  final String path;
  final String? name;
  final bool authRequired;

  static _LanEndpoint? parse(Uint8List value) {
    try {
      final decoded = jsonDecode(utf8.decode(value));
      if (decoded is! Map) return null;
      if (decoded['type'] != 'wmr_ble_endpoint') return null;
      final bridgeId = decoded['bridge_id'];
      final port = decoded['port'];
      final hostsValue = decoded['hosts'];
      if (bridgeId is! String || bridgeId.isEmpty) return null;
      if (port is! int || port < 1 || port > 65535) return null;
      final hosts = <String>[];
      if (hostsValue is List) {
        for (final host in hostsValue) {
          if (host is String && host.trim().isNotEmpty) hosts.add(host);
        }
      }
      if (hosts.isEmpty) return null;
      final pathValue = decoded['path'];
      final name = decoded['name'];
      return _LanEndpoint(
        bridgeId: bridgeId,
        hosts: List.unmodifiable(hosts),
        port: port,
        path: pathValue is String && pathValue.startsWith('/')
            ? pathValue
            : wmrWsDefaultPath,
        name: name is String && name.isNotEmpty ? name : null,
        authRequired: decoded['authRequired'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
