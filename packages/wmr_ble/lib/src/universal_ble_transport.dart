import 'dart:async';
import 'dart:typed_data';

import 'package:wmr_core/protocol/bridge_status.dart';
import 'package:wmr_core/protocol/gatt.dart';

import 'ble_adapter.dart';

import 'package:wmr_core/ble/ble_transport.dart';

/// Where the link to the bridge currently is. The failure phases double as
/// the reason carried by [BleTransportException].
enum BleLinkPhase {
  idle,
  scanning,
  connecting,
  negotiatingMtu,
  discovering,
  subscribing,
  ready,
  disconnecting,
  disconnected,

  // Failures.
  bluetoothOff,
  bluetoothUnavailable,
  permissionDenied,
  scanTimeout,
  connectFailed,
  serviceNotFound,
  connectionLost,
}

class BleTransportException implements Exception {
  const BleTransportException(this.phase, this.message);

  final BleLinkPhase phase;
  final String message;

  @override
  String toString() => 'BleTransportException(${phase.name}): $message';
}

/// A snapshot of the link, for the UI.
class BleLinkStatus {
  const BleLinkStatus(
    this.phase, {
    this.deviceId,
    this.message,
    this.mtu,
    this.priorityRequested,
    this.warnings = const [],
  });

  final BleLinkPhase phase;
  final String? deviceId;
  final String? message;

  /// ATT MTU as reported by the stack after the request, never the value
  /// that was asked for. Null until negotiated or when the request failed.
  final int? mtu;

  /// True once high connection priority was requested successfully; null
  /// where the platform has no such call (everything but Android).
  final bool? priorityRequested;

  /// Setup steps that failed without stopping the connection.
  final List<String> warnings;

  bool get isFailure => phase.index >= BleLinkPhase.bluetoothOff.index;
}

class _Session {
  _Session(this.deviceId);

  final String deviceId;
  int? mtu;
  bool? priorityRequested;
  final List<String> warnings = [];
  bool ready = false;
  final Set<String> enabled = {};

  /// The GATT table discovered during [UniversalBleTransport._setup]. Cached
  /// so a later [UniversalBleTransport.discoverServices] from the facade does
  /// not run a second platform discovery on a live stream.
  List<BleServiceInfo>? services;
}

class _Wanted {
  const _Wanted(this.deviceId, this.serviceUuid, this.characteristicUuid);

  final String deviceId;
  final String serviceUuid;
  final String characteristicUuid;
}

/// [BleTransport] on top of a [BleAdapter] (in production `universal_ble`).
///
/// [connect] runs the bridge's connection sequence: link, MTU request (the
/// negotiated value is recorded), high connection priority where available,
/// service discovery and a check for FF10/FF11. [subscribe] enables
/// notifications once that finished. Every GATT step is serialized and the
/// whole sequence runs again on every [connect], because the bridge forgets
/// the subscription when the link drops. After an unexpected drop the
/// transport only reports [BleLinkPhase.connectionLost]; the caller
/// reconnects.
///
/// Not verified on hardware.
class UniversalBleTransport implements BleTransport {
  UniversalBleTransport({
    required BleAdapter adapter,
    MonotonicClock? clock,
    this.scanTimeout = const Duration(seconds: 15),
    this.availabilityWait = const Duration(seconds: 3),
    this.requestedMtu = wmrRequestedMtu,
  }) : _adapter = adapter,
       clock = clock ?? MonotonicClock() {
    _paramsSub = adapter.connectionParams.listen(
      (p) => _intervalUs[p.deviceId] = p.intervalUs,
    );
  }

  final BleAdapter _adapter;
  final Duration scanTimeout;
  final Duration availabilityWait;
  final int requestedMtu;

  @override
  final MonotonicClock clock;

  BleLinkStatus _status = const BleLinkStatus(BleLinkPhase.idle);
  final StreamController<BleLinkStatus> _statusCtl =
      StreamController.broadcast();

  BleLinkStatus get status => _status;
  Stream<BleLinkStatus> get statusChanges => _statusCtl.stream;

  Future<void> _tail = Future.value();
  final Map<String, _Session> _sessions = {};
  final Map<String, BleLinkStatus> _deviceStatuses = {};
  final Set<String> _connecting = {};
  final Map<String, BleConnectionState> _states = {};
  final Map<String, StreamController<BleConnectionState>> _stateCtls = {};
  final Map<String, StreamSubscription<AdapterConnectionEvent>> _linkSubs = {};

  final Map<String, _Wanted> _wanted = {};
  final Map<String, StreamController<BleNotification>> _streams = {};
  final Map<String, StreamSubscription<Uint8List>> _valueSubs = {};
  final Map<String, int> _intervalUs = {};
  StreamSubscription<AdapterConnectionParams>? _paramsSub;

  StreamController<BleScanResult>? _scanCtl;
  StreamSubscription<BleScanResult>? _scanSub;
  Timer? _scanTimer;
  List<String> _scanServices = const [];
  List<String> _scanNamePrefixes = const [];
  bool _scanWanted = false;
  bool _scanPaused = false;
  bool _adapterScanning = false;
  int _scanSeen = 0;
  Future<void> _scanTail = Future.value();

  /// Runs [op] after every earlier scan operation finished. Pause, resume,
  /// start and stop therefore cannot interleave their platform calls.
  Future<void> _enqueueScan(Future<void> Function() op) {
    final next = _scanTail.then((_) => op());
    _scanTail = next.catchError((Object _) {});
    return next;
  }

  BleLinkStatus statusFor(String deviceId) =>
      _deviceStatuses[deviceId] ?? const BleLinkStatus(BleLinkPhase.idle);

  Map<String, BleLinkStatus> get deviceStatuses =>
      Map.unmodifiable(_deviceStatuses);

  /// Runs [op] after every earlier GATT operation finished.
  Future<T> _serial<T>(Future<T> Function() op) {
    final done = Completer<void>();
    final previous = _tail;
    _tail = done.future;
    return previous
        .then((_) {
          return op();
        })
        .whenComplete(done.complete);
  }

  void _emit(BleLinkPhase phase, {String? deviceId, String? message}) {
    final s = deviceId != null
        ? _sessions[deviceId]
        : _sessions.values.lastOrNull;
    final status = BleLinkStatus(
      phase,
      deviceId: deviceId ?? s?.deviceId,
      message: message,
      mtu: s?.mtu,
      priorityRequested: s?.priorityRequested,
      warnings: List.unmodifiable(s?.warnings ?? const []),
    );
    if (deviceId != null) {
      _deviceStatuses[deviceId] = status;
    }
    _status = status;
    if (!_statusCtl.isClosed) _statusCtl.add(_status);
  }

  BleTransportException _fail(
    BleLinkPhase phase,
    String message, {
    String? deviceId,
  }) {
    _emit(phase, deviceId: deviceId, message: message);
    return BleTransportException(phase, message);
  }

  void _setState(String deviceId, BleConnectionState state) {
    _states[deviceId] = state;
    _stateCtl(deviceId).add(state);
  }

  StreamController<BleConnectionState> _stateCtl(String deviceId) => _stateCtls
      .putIfAbsent(deviceId, StreamController<BleConnectionState>.broadcast);

  /// Permissions first, then the radio. Throws a classified
  /// [BleTransportException].
  Future<void> _preflight({String? deviceId}) async {
    try {
      if (!await _adapter.hasPermissions()) {
        await _adapter.requestPermissions();
      }
    } catch (e) {
      throw _fail(
        BleLinkPhase.permissionDenied,
        'Bluetooth permission denied: $e',
        deviceId: deviceId,
      );
    }
    var state = await _adapter.availability();
    if (state == BleAvailability.unknown ||
        state == BleAvailability.resetting) {
      try {
        state = await _adapter.availabilityChanges
            .firstWhere(
              (s) =>
                  s != BleAvailability.unknown &&
                  s != BleAvailability.resetting,
            )
            .timeout(availabilityWait);
      } on TimeoutException {
        throw _fail(
          BleLinkPhase.bluetoothUnavailable,
          'Bluetooth state is still ${state.name}',
          deviceId: deviceId,
        );
      }
    }
    switch (state) {
      case BleAvailability.poweredOn:
        return;
      case BleAvailability.poweredOff:
        throw _fail(
          BleLinkPhase.bluetoothOff,
          'Bluetooth is turned off',
          deviceId: deviceId,
        );
      case BleAvailability.unauthorized:
        throw _fail(
          BleLinkPhase.permissionDenied,
          'Bluetooth access is not authorized',
          deviceId: deviceId,
        );
      default:
        throw _fail(
          BleLinkPhase.bluetoothUnavailable,
          'Bluetooth is not available (${state.name})',
          deviceId: deviceId,
        );
    }
  }

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) {
    // Always match the advertised name as well as the service.
    final services = withServices.isEmpty
        ? [wmrBridgeServiceUuid]
        : withServices;
    _scanServices = services;
    _scanNamePrefixes = [wmrBridgeDeviceName];
    _scanWanted = true;
    _scanSeen = 0;
    late final StreamController<BleScanResult> ctl;
    ctl = StreamController<BleScanResult>(
      onListen: () {
        _scanCtl = ctl;
        unawaited(_enqueueScan(() => _startScan(ctl)));
      },
      onCancel: stopScan,
    );
    _scanCtl = ctl;
    return ctl.stream;
  }

  Future<void> _startScan(StreamController<BleScanResult> ctl) async {
    if (!_scanWanted || _scanPaused || ctl.isClosed) return;
    if (_adapterScanning) return;
    try {
      await _preflight();
    } on BleTransportException catch (e) {
      // A pause during preflight wins: the resume retries preflight and can
      // report the real cause instead of closing the stream here.
      if (!_scanWanted || _scanPaused || ctl.isClosed) return;
      _scanWanted = false;
      ctl.addError(e);
      unawaited(ctl.close());
      return;
    } catch (e) {
      if (!_scanWanted || _scanPaused || ctl.isClosed) return;
      _scanWanted = false;
      ctl.addError(_fail(BleLinkPhase.connectFailed, 'Scan failed: $e'));
      unawaited(ctl.close());
      return;
    }
    if (!_scanWanted || _scanPaused || ctl.isClosed) return;
    if (_adapterScanning) return;

    try {
      _scanSub ??= _adapter.scanResults.listen((r) {
        _scanSeen++;
        if (!ctl.isClosed) ctl.add(r);
      });
      _scanSeen = 0;
      await _adapter.startScan(
        withServices: _scanServices,
        withNamePrefixes: _scanNamePrefixes,
      );
      _adapterScanning = true;
      _emit(BleLinkPhase.scanning);
      _armScanTimer(ctl);
    } on BleTransportException catch (e) {
      _adapterScanning = false;
      if (!_scanWanted || _scanPaused || ctl.isClosed) return;
      _scanWanted = false;
      ctl.addError(e);
      unawaited(ctl.close());
    } catch (e) {
      _adapterScanning = false;
      if (!_scanWanted || _scanPaused || ctl.isClosed) return;
      _scanWanted = false;
      ctl.addError(_fail(BleLinkPhase.connectFailed, 'Scan failed: $e'));
      unawaited(ctl.close());
    }
  }

  void _armScanTimer(StreamController<BleScanResult> ctl) {
    _scanTimer?.cancel();
    _scanTimer = Timer(scanTimeout, () async {
      await stopScan();
      if (ctl.isClosed) return;
      if (_scanSeen == 0) {
        ctl.addError(
          _fail(
            BleLinkPhase.scanTimeout,
            'No bridge found in ${scanTimeout.inSeconds} s',
          ),
        );
      }
      await ctl.close();
    });
  }

  /// Suspends scanning while the host is not active and resumes it with the
  /// same filters when the host comes back.
  ///
  /// Hosts forward their app-lifecycle state through this; the package does
  /// not import `dart:ui` or Flutter widgets itself. Connections are
  /// deliberately left alone: the link may survive a short background period,
  /// and dropping it would turn a resume into a reconnect.
  ///
  /// Operations are queued, so a pause that arrives while a start is still in
  /// preflight is honoured, and a quick pause/resume pair cannot let an old
  /// stop land after the new start.
  Future<void> handleAppLifecycle(BleAppLifecycle state) {
    final ctl = _scanCtl;
    if (state == BleAppLifecycle.resumed) {
      if (!_scanPaused) return Future.value();
      _scanPaused = false;
      if (!_scanWanted || ctl == null || ctl.isClosed) return Future.value();
      return _enqueueScan(() => _startScan(ctl));
    }

    if (_scanPaused) return Future.value();
    _scanPaused = true;
    _scanTimer?.cancel();
    _scanTimer = null;
    if (!_scanWanted) return Future.value();
    return _enqueueScan(_stopScan);
  }

  Future<void> _stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (!_adapterScanning) return;
    try {
      await _adapter.stopScan();
    } catch (_) {
      // The platform may already have stopped the scan when it suspended us.
    }
    _adapterScanning = false;
    if (_status.phase == BleLinkPhase.scanning) {
      final readySession = _sessions.values.cast<_Session?>().firstWhere(
        (s) => s != null && s.ready,
        orElse: () => null,
      );
      if (readySession != null) {
        _emit(BleLinkPhase.ready, deviceId: readySession.deviceId);
      } else {
        _emit(BleLinkPhase.idle);
      }
    }
  }

  @override
  Future<void> stopScan() async {
    _scanWanted = false;
    _scanPaused = false;
    _scanTimer?.cancel();
    _scanTimer = null;
    final sub = _scanSub;
    _scanSub = null;
    await sub?.cancel();
    await _enqueueScan(_stopScan);
  }

  @override
  Future<void> connect(String deviceId) {
    if (_sessions[deviceId]?.ready == true) {
      return Future.value();
    }
    _connecting.add(deviceId);
    return _serial(() => _setup(deviceId))
        .whenComplete(() => _connecting.remove(deviceId));
  }

  Future<void> _setup(String deviceId) async {
    final session = _sessions[deviceId] = _Session(deviceId);
    _setState(deviceId, BleConnectionState.connecting);
    _emit(BleLinkPhase.connecting, deviceId: deviceId);
    var linkAttempted = false;
    try {
      await _preflight(deviceId: deviceId);
      await _linkSubs[deviceId]?.cancel();
      _linkSubs[deviceId] = _adapter
          .connectionEvents(deviceId)
          .listen((e) => _onLinkEvent(session, e));

      linkAttempted = true;
      try {
        await _adapter.connect(deviceId);
      } catch (e) {
        throw _fail(
          BleLinkPhase.connectFailed,
          'Connect failed: $e',
          deviceId: deviceId,
        );
      }

      _emit(BleLinkPhase.negotiatingMtu, deviceId: deviceId);
      try {
        session.mtu = await _adapter.requestMtu(deviceId, requestedMtu);
      } catch (e) {
        session.warnings.add('MTU request failed: $e');
      }

      if (_adapter.supportsConnectionPriority) {
        try {
          await _adapter.requestHighConnectionPriority(deviceId);
          session.priorityRequested = true;
        } catch (e) {
          session.priorityRequested = false;
          session.warnings.add('Connection priority request failed: $e');
        }
      }

      _emit(BleLinkPhase.discovering, deviceId: deviceId);
      final List<BleServiceInfo> services;
      try {
        services = await _adapter.discoverServices(deviceId);
      } catch (e) {
        throw _fail(
          BleLinkPhase.connectFailed,
          'Service discovery failed: $e',
          deviceId: deviceId,
        );
      }
      final hasStream = services.any(
        (s) =>
            s.uuid.toLowerCase() == wmrBridgeServiceUuid &&
            s.characteristicUuids.any(
              (c) => c.toLowerCase() == wmrBridgeStreamCharUuid,
            ),
      );
      if (!hasStream) {
        throw _fail(
          BleLinkPhase.serviceNotFound,
          'Service FF10 / characteristic FF11 not found',
          deviceId: deviceId,
        );
      }
      if (_sessions[deviceId] != session) {
        throw _fail(
          BleLinkPhase.connectionLost,
          'Disconnected during setup',
          deviceId: deviceId,
        );
      }

      session.services = List.unmodifiable(services);
      session.ready = true;
      for (final key in _wanted.keys.toList()) {
        final w = _wanted[key]!;
        if (w.deviceId != deviceId) continue;
        try {
          await _enable(session, key, w);
        } on BleAdapterException catch (e) {
          // A refused second stream is reported on that stream, not as a
          // failed connection. Anything else keeps failing the setup.
          if (e.attError != attErrorOtherStreamActive) rethrow;
          _streams[key]?.addError(_streamFault(w, e));
        }
      }
      _setState(deviceId, BleConnectionState.connected);
      _emit(BleLinkPhase.ready, deviceId: deviceId);
    } catch (e) {
      if (_sessions[deviceId] == session) _sessions.remove(deviceId);
      _setState(deviceId, BleConnectionState.disconnected);
      if (linkAttempted) {
        try {
          await _adapter.disconnect(deviceId);
        } catch (_) {}
      }
      if (e is BleTransportException) rethrow;
      throw _fail(BleLinkPhase.connectFailed, '$e', deviceId: deviceId);
    }
  }

  void _onLinkEvent(_Session session, AdapterConnectionEvent e) {
    if (e.connected || _sessions[session.deviceId] != session) return;
    final wasReady = session.ready;
    _sessions.remove(session.deviceId);
    _linkSubs.remove(session.deviceId)?.cancel();
    _setState(session.deviceId, BleConnectionState.disconnected);
    // During setup the failing step reports the error; only a drop after
    // setup is an unexpected disconnect.
    if (wasReady) {
      _emit(
        BleLinkPhase.connectionLost,
        deviceId: session.deviceId,
        message: e.error ?? 'Connection lost',
      );
    }
  }

  Future<void> _enable(_Session session, String key, _Wanted w) async {
    if (session.enabled.contains(key)) return;
    _emit(BleLinkPhase.subscribing);
    await _adapter.enableNotifications(
      w.deviceId,
      w.serviceUuid,
      w.characteristicUuid,
    );
    session.enabled.add(key);
  }

  Future<void> _disable(_Session session, String key, _Wanted w) async {
    if (!session.enabled.contains(key)) return;
    await _adapter.disableNotifications(
      w.deviceId,
      w.serviceUuid,
      w.characteristicUuid,
    );
    session.enabled.remove(key);
  }

  static BleStreamException _streamFault(
    _Wanted w,
    BleAdapterException e, {
    bool disabling = false,
  }) {
    final kind = disabling
        ? BleStreamFaultKind.disableFailed
        : e.attError == attErrorOtherStreamActive
        ? BleStreamFaultKind.otherStreamActive
        : BleStreamFaultKind.enableFailed;
    return BleStreamException(
      kind,
      w.characteristicUuid,
      e.message,
      attError: e.attError,
    );
  }

  /// FF11, FF12 and FF14 share one CCC slot on the bridge.
  static bool _isBridgeStream(String key) =>
      key.endsWith('|$wmrBridgeStreamCharUuid') ||
      key.endsWith('|$wmrBridgeDecodedCharUuid') ||
      key.endsWith('|$wmrBridgeBatchedCharUuid');

  @override
  Future<void> disconnect(String deviceId) async {
    // Clearing the session first makes the link event this causes harmless.
    _sessions.remove(deviceId);
    _emit(BleLinkPhase.disconnecting, deviceId: deviceId);
    await _closeStreams(deviceId);
    try {
      await _adapter.disconnect(deviceId);
    } finally {
      _linkSubs.remove(deviceId)?.cancel();
      _setState(deviceId, BleConnectionState.disconnected);
      _emit(BleLinkPhase.disconnected, deviceId: deviceId);
    }
  }

  Future<void> _closeStreams(String deviceId) async {
    final prefix = '$deviceId|';
    for (final key
        in _valueSubs.keys.where((k) => k.startsWith(prefix)).toList()) {
      _valueSubs.remove(key)?.cancel();
    }
    for (final key
        in _streams.keys.where((k) => k.startsWith(prefix)).toList()) {
      _streams.remove(key)?.close();
    }
    _wanted.removeWhere((k, _) => k.startsWith(prefix));
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) async* {
    yield _states[deviceId] ?? BleConnectionState.disconnected;
    yield* _stateCtl(deviceId).stream;
  }

  @override
  Future<List<BleServiceInfo>> discoverServices(String deviceId) {
    // The connect sequence already discovered the bridge's table. Returning it
    // avoids a second platform discovery now that notifications are live.
    final cached = _sessions[deviceId]?.services;
    if (cached != null) return Future.value(cached);
    return _serial(() => _adapter.discoverServices(deviceId));
  }

  @override
  Stream<BleNotification> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final session = _sessions[deviceId];
    final active = session != null && session.ready;
    if (!active && !_connecting.contains(deviceId)) {
      throw StateError('Device $deviceId is not connected');
    }
    final key = '$deviceId|${characteristicUuid.toLowerCase()}';
    final ctl = _streams.putIfAbsent(
      key,
      StreamController<BleNotification>.broadcast,
    );
    _valueSubs.putIfAbsent(
      key,
      () => _adapter.notifications(deviceId, characteristicUuid).listen((v) {
        // Stamp first; nothing else happens on this path.
        final t = clock.nowUs;
        if (!ctl.isClosed) {
          ctl.add(BleNotification(value: v, receivedAtUs: t));
        }
      }),
    );
    // FF11, FF12 and FF14 are mutually exclusive on the bridge. Forget the
    // others now, so a setup that is already queued enables only this one.
    if (_isBridgeStream(key)) {
      _wanted.removeWhere(
        (k, _) => k != key && k.startsWith('$deviceId|') && _isBridgeStream(k),
      );
    }
    final w = _wanted[key] = _Wanted(deviceId, serviceUuid, characteristicUuid);
    // Queued behind any setup in progress, so it only runs after the MTU
    // result, priority and discovery. A no-op if setup already enabled it.
    unawaited(
      _serial(() async {
        final session = _sessions[deviceId];
        if (session == null || !session.ready) {
          return;
        }
        // Superseded by a later subscribe or unsubscribe while queued.
        if (_wanted[key] != w) return;
        // Switching: 0x0000 to the active CCC first, then enable this one.
        if (_isBridgeStream(key)) {
          final active = session.enabled
              .where((k) => k != key && _isBridgeStream(k))
              .toList();
          for (final k in active) {
            final other = _Wanted(
              deviceId,
              wmrBridgeServiceUuid,
              k.substring(deviceId.length + 1),
            );
            try {
              await _disable(session, k, other);
            } catch (e) {
              if (!ctl.isClosed) {
                ctl.addError(
                  _streamFault(
                    other,
                    e is BleAdapterException ? e : BleAdapterException('$e'),
                    disabling: true,
                  ),
                );
              }
              return;
            }
          }
        }
        try {
          await _enable(session, key, w);
        } on BleAdapterException catch (e) {
          if (!ctl.isClosed) ctl.addError(_streamFault(w, e));
          if (e.attError != attErrorOtherStreamActive) {
            _fail(
              BleLinkPhase.connectFailed,
              'Enable notifications failed: $e',
              deviceId: deviceId,
            );
          } else if (_status.phase == BleLinkPhase.subscribing) {
            _emit(BleLinkPhase.ready, deviceId: deviceId);
          }
          return;
        }
        if (_status.phase == BleLinkPhase.subscribing) {
          _emit(BleLinkPhase.ready, deviceId: deviceId);
        }
      }).catchError((Object e) {
        if (!ctl.isClosed) ctl.addError(e);
        _fail(
          BleLinkPhase.connectFailed,
          'Enable notifications failed: $e',
          deviceId: deviceId,
        );
      }),
    );
    return ctl.stream;
  }

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    final key = '$deviceId|${characteristicUuid.toLowerCase()}';
    final w = _wanted.remove(key);
    return _serial(() async {
      final session = _sessions[deviceId];
      if (w == null || session == null || !session.ready) {
        return;
      }
      await _disable(session, key, w);
    });
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) {
    return _serial(
      () => _adapter.read(deviceId, serviceUuid, characteristicUuid),
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
    return _serial(
      () => _adapter.write(
        deviceId,
        serviceUuid,
        characteristicUuid,
        value,
        withoutResponse: withoutResponse,
      ),
    );
  }

  /// Reads the 16-byte FF11 status once. On demand only: never call this at
  /// stream rate. Null if the value does not parse.
  Future<BridgeStatus?> readBridgeStatus(String deviceId) async {
    final bytes = await _serial(
      () => _adapter.read(
        deviceId,
        wmrBridgeServiceUuid,
        wmrBridgeStreamCharUuid,
      ),
    );
    return BridgeStatus.parse(bytes);
  }

  /// MTU negotiated for the current session, or null.
  int? negotiatedMtu(String deviceId) => _sessions[deviceId]?.mtu;

  /// PHY is not exposed by universal_ble, so it stays null. The connection
  /// interval is only known after Android reports a parameter update.
  @override
  Future<BleConnectionInfo> connectionInfo(String deviceId) async {
    final session = _sessions[deviceId];
    if (session == null || !session.ready) {
      throw StateError('Device $deviceId is not connected');
    }
    int? rssi;
    try {
      rssi = await _adapter.readRssi(deviceId);
    } catch (_) {}
    return BleConnectionInfo(
      mtu: session.mtu,
      rssi: rssi,
      connectionIntervalUs: _intervalUs[deviceId],
    );
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await _scanCtl?.close();
    for (final s in _linkSubs.values) {
      await s.cancel();
    }
    _linkSubs.clear();
    await _paramsSub?.cancel();
    for (final s in _valueSubs.values) {
      await s.cancel();
    }
    for (final c in _streams.values) {
      await c.close();
    }
    for (final c in _stateCtls.values) {
      await c.close();
    }
    _valueSubs.clear();
    _streams.clear();
    _stateCtls.clear();
    await _statusCtl.close();
  }
}
