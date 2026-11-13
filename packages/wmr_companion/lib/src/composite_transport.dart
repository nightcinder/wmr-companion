import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_ws/wmr_ws.dart';

/// Which leg of a [CompositeBleTransport] currently carries a bridge.
enum CompositeLeg { tcp, ble }

/// A [BleTransport] that prefers the Pi's WebSocket (TCP) link and falls back
/// to BLE GATT, keeping one logical connection across the switch.
///
/// The primary transport is a [WmrWsTransport] (the Linux/Raspberry Pi daemon
/// on `ws://<host>:8765/wmr`). The fallback is any [BleTransport], normally
/// `UniversalBleTransport` from `wmr_ble`. A bridge is dialled over TCP when
/// an endpoint is known, either because the caller configured/discovered one
/// or because the FF16 endpoint document was read over BLE. When TCP cannot
/// connect, or drops later, the same bridge is dialled over BLE GATT. While
/// the bridge is on BLE, [upgradeInterval] retries TCP; when it succeeds the
/// notification subscriptions move to TCP without being closed. TCP is probed
/// only while a LAN interface is up, and never for longer than
/// [tcpProbeBudget], so a phone with Wi-Fi off reaches BLE immediately.
///
/// Bridges are identified by the daemon's stable `bridge_id` once a hello or
/// an FF16 endpoint document has supplied it. Two scan results that resolve
/// to the same id are published once by [scan]. Before an id has been learned,
/// a BLE result and a TCP result cannot be matched, so both are published.
///
/// ## BLE radio use
///
/// Following the per-client CCCD rule, the composite turns its own BLE
/// notifications off when TCP becomes active. It writes 0x0000 only to the
/// characteristics it had enabled; it never asks the bridge to silence other
/// clients. FF15 (echo) is the exception: it stays on until the answers to
/// pings already written on BLE have landed, then goes off too.
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
    this.tcpProbeBudget = const Duration(seconds: 3),
    this.echoDrainTimeout = const Duration(milliseconds: 1200),
    this.lanAvailable,
    this.disposeBle = true,
    this.onTokenLearned,
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

  /// Total time allowed for dialling the TCP candidates of one bridge.
  ///
  /// The BLE leg is always available here, so a Wi-Fi dial that hangs must not
  /// hold the session: after the budget the composite gives up on TCP and
  /// dials BLE instead. Each candidate gets an equal share of what is left, so
  /// a dead address cannot consume the whole budget before a live one is
  /// tried. A non-positive duration disables the TCP probe entirely.
  final Duration tcpProbeBudget;

  /// How long a BLE FF15 echo subscription is kept open after the route moves
  /// to TCP, waiting for the answers to pings already written on BLE.
  ///
  /// The bridge answers FF15 only while its CCCD is on, so cancelling the
  /// subscription during the upgrade drops the last ping and the app reports a
  /// timeout. Once the answers land (or this window closes) the subscription
  /// is cancelled and the CCCD turned off. A non-positive duration cancels it
  /// at once.
  final Duration echoDrainTimeout;

  /// Whether a LAN interface is currently up, checked before any TCP probe.
  ///
  /// A host supplies this (the companion app checks its network interfaces).
  /// With Wi-Fi off, dialling the Pi's remembered LAN address can only time
  /// out, and doing so before the BLE fallback is what made a Bluetooth
  /// connect look like a 30 s stall. Null means unknown, and TCP is attempted.
  final Future<bool> Function()? lanAvailable;

  /// Whether [dispose] also disposes [ble]. A host that shares one BLE
  /// transport between several composites (the Bluetooth tab and an opt-in
  /// Wi-Fi fallback) sets this to false and owns the transport itself.
  final bool disposeBle;

  /// Called when the FF13 encrypted read supplies the bridge token, with the
  /// stable `bridge_id`, the LAN hosts and the port the FF16 document
  /// reported.
  ///
  /// The composite keeps the token only for the current dial. A host that
  /// wants it after an app restart, so Wi-Fi can authenticate while Bluetooth
  /// is off, saves it here together with the endpoint (hosts and port). The
  /// callback must not log the token; an exception it throws is swallowed so
  /// the dial still proceeds.
  final void Function(
    String bridgeId,
    List<String> hosts,
    int port,
    String token,
  )?
  onTokenLearned;

  final Map<String, _Route> _routes = {};
  final Map<String, String> _bridgeIds = {};
  final Map<String, _ScanHit> _scanHits = {};
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
    if (route.switching) {
      // A failover or loss is already changing this route. Wait for it so an
      // explicit reconnect is not swallowed while the old subscriptions are
      // being detached.
      final done = route.switchingDone;
      if (done != null) await done.future;
      if (route.state == BleConnectionState.connected || route.switching)
        return;
    }
    if (route.state == BleConnectionState.connected) return;
    route.intentional = false;
    route.switching = true;
    // Publish the completer like the failover and recovery paths do, so an
    // upgrade probe that finishes mid-connect can wait for this switch to
    // release the route before it decides who owns its socket.
    final switchingDone = route.switchingDone = Completer<void>();
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
          if (route.bleDeviceId == bleId) await _rejectBle(route);
          bleError = error;
        }
      }
    } finally {
      route.switching = false;
      _kickUpgrade(route);
      if (identical(route.switchingDone, switchingDone)) {
        route.switchingDone = null;
      }
      if (!switchingDone.isCompleted) switchingDone.complete();
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
      // Do not await these cancels: a transport's connection-state stream can
      // defer cancellation until a later delivery turn, which would make an
      // explicit Disconnect look stuck.
      final tcpSub = route.tcpStateSub;
      final bleSub = route.bleStateSub;
      route.tcpStateSub = null;
      route.bleStateSub = null;
      route.tcpStateId = null;
      route.bleStateId = null;
      unawaited(tcpSub?.cancel());
      unawaited(bleSub?.cancel());
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
    }
  }

  /// Turns this client's BLE stream notifications off and keeps the link.
  ///
  /// A host moving a bridge to Wi-Fi calls this instead of [disconnect]: this
  /// client's FF11/FF12/FF14 CCCD notifications are turned off (0x0000), the
  /// open streams are detached and the TCP leg is closed, but [ble] is never
  /// told to disconnect. The bonded GATT link therefore survives a Wi-Fi
  /// connect or a tab switch; a later [connect] re-subscribes over it, and
  /// only an explicit [disconnect] or [dispose] drops it.
  Future<void> suspendBleStreams(String deviceId) async {
    final route = _routes[deviceId];
    if (route == null) return;
    _stopUpgrade(route);
    final tcpSub = route.tcpStateSub;
    route.tcpStateSub = null;
    route.tcpStateId = null;
    unawaited(tcpSub?.cancel());
    await _disableBleNotifications(route);

    final channels = List<_Channel>.of(route.channels);
    for (final channel in channels) {
      await channel.detach();
    }

    final tcpId = route.tcpDeviceId;
    route.tcpDeviceId = null;
    if (tcpId != null) {
      try {
        await tcp.disconnect(tcpId);
      } catch (_) {
        // A link that already dropped needs no further teardown.
      }
    }
    // Deliberately no `ble.disconnect`: the bonded link stays up so the
    // bridge keeps seeing the phone.
    if (route.bleDeviceId != null) route.active = _Lane.ble;
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
    final route = _routes[deviceId];
    final echo =
        route != null &&
        identical(active.transport, ble) &&
        characteristicUuid.toLowerCase() == wmrBridgeEchoCharUuid;
    if (echo) route.echoRequestSent();
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
      final tcpSub = route.tcpStateSub;
      final bleSub = route.bleStateSub;
      route.tcpStateSub = null;
      route.bleStateSub = null;
      route.tcpStateId = null;
      route.bleStateId = null;
      unawaited(tcpSub?.cancel());
      unawaited(bleSub?.cancel());
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
    }
    await tcp.dispose();
    if (disposeBle) await ble.dispose();
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('CompositeBleTransport is disposed');
  }

  _Route _ensureRoute(String deviceId) =>
      _routes.putIfAbsent(deviceId, () => _Route(deviceId, tcp, ble, clock));

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
    if (tcp.endpointFor(deviceId) != null) ids.add(deviceId);
    return ids.toList();
  }

  Future<String?> _tryTcp(_Route route, List<String> candidates) async {
    if (candidates.isEmpty) return null;
    if (tcpProbeBudget <= Duration.zero) return null;
    if (!await _lanAvailable()) return null;
    Object? lastError;
    final stopwatch = Stopwatch()..start();
    var left = candidates.length;
    for (final id in candidates) {
      final remaining = tcpProbeBudget - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      // Share what is left evenly, so one unresponsive address cannot use the
      // whole budget and hide a reachable candidate behind it.
      final slice = remaining ~/ left;
      left--;
      route.tcpCandidates.add(id);
      // Each attempt owns its dial. A transport can hand a later probe the
      // same in-flight connection, so the cleanup of an abandoned dial must
      // not close one that has since been taken over.
      final dial = ++route.tcpDialSeq;
      route.tcpDials[id] = dial;
      final pending = tcp.connect(id);
      try {
        await pending.timeout(slice);
        if (route.tcpDials[id] == dial) route.tcpDials.remove(id);
        route.tcpDeviceId = id;
        _rememberBridge(route, tcp.helloFor(id)?.bridgeId);
        return id;
      } on TimeoutException {
        lastError = TimeoutException(
          'TCP connect to $id took longer than ${slice.inMilliseconds} ms',
          slice,
        );
        // The dial may still land after the budget. Close it when it does, so
        // a late socket cannot stay open behind the BLE fallback. If a later
        // probe has joined this dial or an earlier one was adopted, leave the
        // connection alone: closing it here would tear down a live upgrade.
        unawaited(
          pending.then<void>((_) async {
            if (route.tcpDials[id] != dial) return;
            if (route.tcpDeviceId == id) return;
            route.tcpDials.remove(id);
            await tcp.disconnect(id);
          }, onError: (Object _) {}),
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('No TCP endpoint answered');
  }

  Future<bool> _lanAvailable() async {
    final probe = lanAvailable;
    if (probe == null) return true;
    try {
      return await probe();
    } catch (_) {
      // A platform that cannot answer must not disable TCP.
      return true;
    }
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
    final bleSub = route.bleStateSub;
    route.bleStateSub = null;
    route.bleStateId = null;
    unawaited(bleSub?.cancel());
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
  }

  Future<void> _activateBle(_Route route) async {
    _watchBle(route);
    await _switchChannels(route, _Lane.ble);
    _startUpgrade(route);
    _setState(route, BleConnectionState.connected);
  }

  /// Runs the FF16-triggered upgrade kick once the switch that activated BLE
  /// has released `route.switching`. Kicking inside [_activateBle] would hit
  /// the guard in [_attemptUpgrade] while that switch still holds the route.
  void _kickUpgrade(_Route route) {
    if (!route.upgradeNow) return;
    route.upgradeNow = false;
    if (route.active != _Lane.ble) return;
    // An FF16 endpoint document names the LAN hosts during the BLE dial, so
    // try them at once instead of waiting for the first periodic tick. A
    // failed attempt leaves the timer to keep retrying.
    unawaited(_attemptUpgrade(route));
  }

  Future<void> _switchChannels(_Route route, _Lane to) async {
    final currentId = route.deviceIdFor(route.active);
    final nextId = route.deviceIdFor(to);
    if (route.active == to && currentId == nextId) return;

    final live = route.channels.where((channel) => channel.isLive).toList();
    // FF15 echo replies to pings already written on BLE can land after the
    // route moves to TCP. Keep that subscription (and its CCCD) open until the
    // answers drain instead of cancelling it here.
    final draining = <_Channel>[];
    if (to == _Lane.tcp && route.active == _Lane.ble) {
      for (final channel in live) {
        if (channel.isEcho) draining.add(channel);
      }
    }
    if (to == _Lane.tcp) {
      await _disableBleNotifications(
        route,
        keep: draining.map((channel) => channel.refKey).toSet(),
      );
    }
    for (final channel in live) {
      if (draining.contains(channel)) {
        channel.handOffBleToDrain();
      } else {
        await channel.detach();
      }
    }
    route.active = to;
    for (final channel in live) {
      channel.attach();
    }
    for (final channel in draining) {
      unawaited(channel.drainBle(route, echoDrainTimeout));
    }
  }

  Future<void> _disableBleNotifications(
    _Route route, {
    Set<String> keep = const {},
  }) async {
    final bleId = route.bleDeviceId;
    final keys = route.bleRefs.keys.toList();
    for (final key in keys) {
      if (!keep.contains(key)) route.bleRefs.remove(key);
    }
    if (bleId == null) return;
    for (final key in keys) {
      if (keep.contains(key)) continue;
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
    final switchingDone = route.switchingDone = Completer<void>();
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
          if (route.bleDeviceId == bleId) await _rejectBle(route);
          // Try the next scanned bridge before giving up the session.
        }
      }
      await _lose(route);
    } finally {
      route.switching = false;
      _kickUpgrade(route);
      if (identical(route.switchingDone, switchingDone)) {
        route.switchingDone = null;
      }
      if (!switchingDone.isCompleted) switchingDone.complete();
    }
  }

  Future<void> _recoverFromBleDrop(_Route route) async {
    if (_disposed || route.intentional || route.switching) return;
    route.switching = true;
    final switchingDone = route.switchingDone = Completer<void>();
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
      if (identical(route.switchingDone, switchingDone)) {
        route.switchingDone = null;
      }
      if (!switchingDone.isCompleted) switchingDone.complete();
    }
  }

  Future<void> _lose(_Route route) async {
    _stopUpgrade(route);
    // A drop is reported from the BLE subscription's own listener; awaiting
    // that generator's cancel() there can park the loss until the next event.
    // The streams are done after a loss, so detach without waiting.
    final tcpSub = route.tcpStateSub;
    final bleSub = route.bleStateSub;
    route.tcpStateSub = null;
    route.bleStateSub = null;
    route.tcpStateId = null;
    route.bleStateId = null;
    unawaited(tcpSub?.cancel());
    unawaited(bleSub?.cancel());
    final channels = List<_Channel>.of(route.channels);
    for (final channel in channels) {
      await channel.dropBleDrain();
      await channel.detach();
    }
    route.active = null;
    if (!_disposed) _setState(route, BleConnectionState.disconnected);
  }

  Future<void> _attemptUpgrade(_Route route) async {
    if (_disposed || route.intentional || route.upgrading) return;
    // A failover or loss owns the route right now; it will kick again if
    // BLE is the lane it leaves active.
    if (route.switching) return;
    if (route.active != _Lane.ble || route.tcpCandidates.isEmpty) return;
    route.upgrading = true;
    try {
      final id = await _tryTcp(route, route.tcpCandidates.toList());
      if (id == null) return;
      // A drop, failover or connect may own the route right now, and it can
      // adopt this same socket (the transport hands out in-flight dials to
      // every joiner). Decide only once that switch has released the route:
      // whoever adopted the socket keeps it, and nobody else may close it.
      await _awaitSwitchRelease(route);
      if (route.switching) {
        // That switch published no completion, so the route is still not
        // settled: it may adopt this dial, and the probe must not close it.
        return;
      }
      if (_disposed || route.intentional || route.active != _Lane.ble) {
        // The route moved on while this probe was dialling.
        await _discardTcpProbe(route, id);
        return;
      }
      await _activateTcp(route, id);
    } catch (_) {
      // Stay on BLE; the next tick retries.
    } finally {
      route.upgrading = false;
    }
  }

  /// Waits until no switch holds the route. A switch that started while a
  /// probe was dialling may adopt the probe's socket, so the probe must not
  /// judge it until that switch has finished.
  Future<void> _awaitSwitchRelease(_Route route) async {
    while (route.switching && !_disposed) {
      final done = route.switchingDone;
      if (done == null) return;
      await done.future;
    }
  }

  Future<void> _discardTcpProbe(_Route route, String id) async {
    // A switch owns the route right now and may still adopt this dial, so the
    // socket is not the probe's to close.
    if (route.switching) return;
    // Never close the socket the route is actively using over TCP. A TCP
    // route on a different candidate does not own this probe's socket, so
    // the probe must still be closed.
    if (route.active == _Lane.tcp && route.tcpDeviceId == id) return;
    // A newer probe or recovery dial owns this candidate; closing it here
    // would tear down the dial that joiner is about to adopt.
    if (route.tcpDials.containsKey(id)) return;
    if (route.tcpDeviceId == id) route.tcpDeviceId = null;
    try {
      await tcp.disconnect(id);
    } catch (_) {
      // The probe socket may already be gone.
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

    String? token;
    if (endpoint.authRequired) {
      token = await _readBleToken(bleId);
      if (token == null) return;
      final learned = onTokenLearned;
      if (learned != null && endpoint.bridgeId.trim().isNotEmpty) {
        try {
          learned(endpoint.bridgeId, endpoint.hosts, endpoint.port, token);
        } catch (_) {
          // Saving the token is best-effort; the dial still proceeds.
        }
      }
    }
    for (final host in endpoint.hosts) {
      final candidate = WmrWsEndpoint(
        host: host,
        port: endpoint.port,
        path: endpoint.path,
        name: endpoint.name,
        bridgeId: endpoint.bridgeId,
        token: token,
      );
      tcp.registerEndpoint(candidate);
      route.tcpCandidates.add(candidate.resolvedDeviceId);
    }
    // The link is about to become active on BLE; retry TCP as soon as it does
    // rather than waiting for the first periodic tick.
    route.upgradeNow = true;
    _startUpgrade(route);
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
  final List<_Channel> channels = [];
  final Map<String, int> bleRefs = {};

  String? bridgeId;
  String? bleDeviceId;
  String? tcpDeviceId;
  final Set<String> tcpCandidates = {};

  /// The dial attempt that currently owns each TCP candidate, so a probe that
  /// timed out can tell whether its connection was adopted or replaced.
  final Map<String, int> tcpDials = {};
  int tcpDialSeq = 0;
  _Lane? active;
  BleConnectionState state = BleConnectionState.disconnected;
  bool intentional = false;
  bool switching = false;
  bool upgrading = false;

  /// Completed when an in-flight failover or loss finishes, so a concurrent
  /// [CompositeBleTransport.connect] can wait instead of returning as if the
  /// route were already dialled.
  Completer<void>? switchingDone;

  /// Set when an FF16 endpoint document supplied LAN hosts during this BLE
  /// dial; [_activateBle] then probes TCP without waiting for a timer tick.
  bool upgradeNow = false;
  StreamSubscription<BleConnectionState>? tcpStateSub;
  StreamSubscription<BleConnectionState>? bleStateSub;
  String? tcpStateId;
  String? bleStateId;
  Timer? upgradeTimer;

  /// FF15 pings written on BLE whose answer has not arrived yet.
  int echoRequestsInFlight = 0;

  /// Completed when [echoRequestsInFlight] reaches zero, so the drain that
  /// follows a BLE-to-TCP switch can cancel the BLE subscription at the right
  /// moment instead of dropping the answer.
  Completer<void>? echoDrained;

  void echoRequestSent() {
    echoRequestsInFlight++;
    echoDrained ??= Completer<void>();
  }

  void echoAnswerReceived() {
    if (echoRequestsInFlight > 0) echoRequestsInFlight--;
    if (echoRequestsInFlight > 0) return;
    final done = echoDrained;
    echoDrained = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Waits for the answers to pings already written on BLE, bounded by
  /// [timeout] so a bridge that never answers cannot pin the CCCD on forever.
  Future<void> waitForEchoDrain(Duration timeout) async {
    if (echoRequestsInFlight == 0) return;
    final done = echoDrained ??= Completer<void>();
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    timer.cancel();
    echoRequestsInFlight = 0;
    if (identical(echoDrained, done)) echoDrained = null;
  }

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

  /// The BLE subscription kept open across a switch to TCP until the FF15
  /// answers already in flight have landed.
  StreamSubscription<BleNotification>? _bleDrain;

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

  /// The FF15 echo characteristic, whose replies may land after a switch.
  bool get isEcho => characteristicUuid == wmrBridgeEchoCharUuid;

  /// The key used by [_Route.bleRefs] for this channel's CCCD.
  String get refKey => '$serviceUuid|$characteristicUuid';

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
              if (isEcho) route.echoAnswerReceived();
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

  /// Moves the live BLE subscription out of the active slot so [attach] can
  /// subscribe on the new lane while the old link stays open.
  void handOffBleToDrain() {
    final subscription = _subscription;
    if (subscription == null) return;
    _subscription = null;
    _bleDrain = subscription;
  }

  /// Cancels a handed-off BLE subscription once its echo answers have drained,
  /// then releases the CCCD that was kept on for it.
  Future<void> drainBle(_Route route, Duration timeout) async {
    if (_bleDrain == null) return;
    await route.waitForEchoDrain(timeout);
    final subscription = _bleDrain;
    if (subscription == null) return;
    _bleDrain = null;
    await subscription.cancel();
    // A fast switch back to BLE re-attached this channel on the same CCCD, so
    // that subscription now owns the ref and the unsubscribe.
    if (route.active == _Lane.ble && _subscription != null) return;
    route.removeBleRef(serviceUuid, characteristicUuid);
    final bleId = route.bleDeviceId;
    if (bleId == null) return;
    try {
      await route.ble.unsubscribe(bleId, serviceUuid, characteristicUuid);
    } catch (_) {
      // The link may already be gone; its CCC went with it.
    }
  }

  /// Cancels a handed-off BLE subscription without the CCCD handshake; the
  /// link that carried it is gone.
  Future<void> dropBleDrain() async {
    final drain = _bleDrain;
    _bleDrain = null;
    await drain?.cancel();
  }

  Future<void> close() async {
    final drain = _bleDrain;
    _bleDrain = null;
    await drain?.cancel();
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
