import 'dart:async';
import 'dart:typed_data';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/domain/axis_mapping.dart';
import 'package:wmr_core/domain/gamepad.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/domain/imu_calibration.dart';
import 'package:wmr_core/domain/stick_centre.dart';
import 'package:wmr_core/protocol/firmware_version.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/controller_service.dart';

import 'config.dart';
import 'errors.dart';
import 'models.dart';

/// The only required import for a host app.
///
/// Owns one bridge session: scan, connect, the requested stream mode, the
/// per-hand pipeline and the gamepad mapping. It exposes plain streams and
/// immutable models, with no Riverpod, widgets or static state, so a host can
/// adapt them to whatever state layer it already uses. Two instances in one
/// process are independent.
///
/// Lifecycle is explicit: [initialize] → [startScan]/[connect] →
/// [setStreamMode] → [dispose]. No work starts in the constructor. The
/// injected [BleTransport] stays owned by the caller: [dispose] closes the
/// active link, subscriptions, service and timers, but not the transport.
class WmrCompanion {
  WmrCompanion({
    required BleTransport ble,
    WmrCompanionConfig config = const WmrCompanionConfig(),
    this.onStickCentre,
  }) : _transport = ble,
       _config = config;

  /// Called when a hand learns a new stick rest centre, so the host can save
  /// it. Restoring a saved centre through [setStickCentre] does not call it.
  final void Function(Hand hand, List<double> centre)? onStickCentre;

  final BleTransport _transport;
  WmrCompanionConfig _config;

  final StreamController<List<WmrBridgeDevice>> _bridges =
      StreamController.broadcast();
  final StreamController<WmrConnectionState> _connection =
      StreamController.broadcast();
  final StreamController<WmrControllerUpdate> _controllers =
      StreamController.broadcast();
  final StreamController<GamepadState> _gamepad = StreamController.broadcast();
  final StreamController<WmrLinkSnapshot> _link = StreamController.broadcast();
  final StreamController<WmrException> _failures = StreamController.broadcast();

  final Map<String, WmrBridgeDevice> _seen = {};
  final List<List<double>?> _stickCentres = [null, null];
  final List<({ImuCalibration? calibration, bool apply})> _calibrations = [
    (calibration: null, apply: false),
    (calibration: null, apply: false),
  ];
  final List<HandInput?> _latestInputs = [null, null];

  WmrConnectionState _state = WmrConnectionState.idle;
  String? _deviceId;
  WmrBridgeDevice? _bridge;
  ControllerService? _service;
  BleConnectionInfo? _lastInfo;
  DecodedStats? _lastStats;
  WmrProtocolVersion? _protocol;
  GamepadState? _previousGamepad;
  String? _reportedFault;

  StreamSubscription<BleScanResult>? _scanSub;
  StreamSubscription<BleConnectionState>? _connectionSub;
  StreamSubscription<ReceivedFrame>? _frameSub;
  StreamSubscription<DecodedSample>? _sampleSub;
  StreamSubscription<ModeState>? _modeSub;
  Timer? _linkTimer;
  Timer? _reconnectTimer;

  bool _disposed = false;
  bool _intentionalDisconnect = false;
  bool _linkUp = false;
  bool _refreshingLink = false;

  /// The current lifecycle state.
  WmrConnectionState get state => _state;

  /// The connected bridge id, or null when not connected.
  String? get deviceId => _deviceId;

  /// The configuration in force. Setters return a new value here.
  WmrCompanionConfig get config => _config;

  /// The connected bridge's firmware version and FF feature matrix, read once
  /// after connect. Null before the first read completes, and when service
  /// discovery failed. Prefer [link], which republishes this on every snapshot.
  WmrProtocolVersion? get protocol => _protocol;

  /// Scan results, strongest first, de-duplicated by id.
  Stream<List<WmrBridgeDevice>> get bridges => _bridges.stream;

  /// Lifecycle changes.
  Stream<WmrConnectionState> get connection => _connection.stream;

  /// One event per FF11 frame (raw mode) or FF12/FF14 sample (decoded modes).
  Stream<WmrControllerUpdate> get controllers => _controllers.stream;

  /// Mapped two-handed gamepad state, one event per decoded sample.
  Stream<GamepadState> get gamepad => _gamepad.stream;

  /// Link parameters and counters, on connect, on mode change and once a
  /// second while connected.
  Stream<WmrLinkSnapshot> get link => _link.stream;

  /// Typed, non-fatal errors: scan failures and stream-mode faults that did
  /// not come from an awaited call. Fatal calls also throw.
  Stream<WmrException> get failures => _failures.stream;

  /// Transitional access to the underlying controller service for the
  /// reference app's diagnostic screens during the phase 2–4 migration.
  ///
  /// Not part of the stable facade: new consumers should use [controllers],
  /// [gamepad] and [link]. It goes away once the app's screens move onto the
  /// facade.
  ControllerService? get debugControllerService => _service;

  /// Resets the session to idle.
  ///
  /// Adapter state and permission checks live in the BLE package (phase 3),
  /// so this phase only validates that the facade is usable. Kept in the
  /// lifecycle so call sites do not change later.
  Future<void> initialize() async {
    _ensureUsable();
    if (_service == null && _state != WmrConnectionState.scanning) {
      _setState(WmrConnectionState.idle);
    }
  }

  /// Starts a scan and publishes [bridges] until [stopScan] or a connect.
  Future<void> startScan() async {
    _ensureUsable();
    await _scanSub?.cancel();
    _seen.clear();
    _bridges.add(const []);
    _setState(WmrConnectionState.scanning);
    _scanSub = _transport.scan().listen(
      (result) {
        final device = WmrBridgeDevice(
          id: result.deviceId,
          name: result.name,
          rssi: result.rssi,
        );
        _seen[device.id] = device;
        final devices = _seen.values.toList()
          ..sort((a, b) => (b.rssi ?? -1000).compareTo(a.rssi ?? -1000));
        if (!_bridges.isClosed) _bridges.add(devices);
      },
      onError: (Object error) {
        final exception = WmrTransportException('Scan failed', cause: error);
        _failures.add(exception);
        if (!_disposed) _setState(WmrConnectionState.failed);
      },
      onDone: () {
        _scanSub = null;
        if (!_disposed && _state == WmrConnectionState.scanning) {
          _setState(
            _service == null
                ? WmrConnectionState.idle
                : WmrConnectionState.ready,
          );
        }
      },
    );
  }

  /// Stops the scan, keeping any connection.
  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _transport.stopScan();
    if (!_disposed && _state == WmrConnectionState.scanning) {
      _setState(
        _service == null ? WmrConnectionState.idle : WmrConnectionState.ready,
      );
    }
  }

  /// Connects to [bridge] and enables [WmrCompanionConfig.streamMode].
  ///
  /// Throws [WmrConnectionException] when the link cannot be established and
  /// [WmrStreamModeException] when the link is up but the stream did not
  /// enable. In the latter case [state] is [WmrConnectionState.ready] and the
  /// fault is on [link]; the caller can retry [setStreamMode].
  Future<void> connect(WmrBridgeDevice bridge) async {
    _ensureUsable();
    await stopScan();
    await _disposeSession();

    _deviceId = bridge.id;
    _bridge = bridge;
    _setState(WmrConnectionState.connecting);

    final service = _service = _createService(bridge.id);
    _subscribeToService(service);
    _watchConnection(bridge.id);

    try {
      await service.start();
    } catch (error) {
      if (!identical(_service, service)) return;
      await _disposeSession();
      final exception = WmrConnectionException(
        'Could not connect to ${bridge.name ?? bridge.id}',
        deviceId: bridge.id,
        cause: error,
      );
      _failures.add(exception);
      _setState(WmrConnectionState.failed);
      throw exception;
    }
    if (_disposed || !identical(_service, service)) return;

    _linkUp = true;
    _setState(WmrConnectionState.ready);
    _startLinkPolling();
    // Read FF16 once, after the transport's MTU/priority setup (which
    // `service.start()` waits for). It never gates the stream: a slow or
    // failed read leaves the snapshot's protocol null, and an older bridge
    // without FF16 is a normal status.
    unawaited(_readProtocol(service));
    final fault = service.fault;
    if (fault != null) {
      throw _reportFault(fault);
    }
  }

  /// Switches the active stream without reconnecting.
  ///
  /// Throws [WmrStreamModeException] when the bridge refuses (for example
  /// ATT 0x80 because another stream is still enabled) or the MTU is too
  /// small for the requested stream.
  Future<void> setStreamMode(StreamMode mode) async {
    _ensureUsable();
    _config = _config.copyWith(streamMode: mode);
    final service = _service;
    if (service == null) {
      _emitLink();
      return;
    }
    try {
      await service.setMode(mode);
    } on WmrException {
      rethrow;
    } catch (error) {
      throw WmrTransportException('Could not switch stream', cause: error);
    }
    // A reconnect during the await replaced the service; the new one already
    // started from the updated config, so its fault belongs to that session.
    if (!identical(service, _service)) return;
    final fault = service.fault;
    if (fault != null) throw _reportFault(fault);
  }

  /// Closes the link and returns to [WmrConnectionState.idle].
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    try {
      await stopScan();
      final id = _deviceId;
      await _disposeSession();
      if (id != null) {
        try {
          await _transport.disconnect(id);
        } catch (error) {
          _failures.add(
            WmrTransportException('Could not disconnect', cause: error),
          );
        }
      }
      _deviceId = null;
      _bridge = null;
      if (!_disposed) _setState(WmrConnectionState.idle);
    } finally {
      _intentionalDisconnect = false;
    }
  }

  /// Replaces the gamepad thresholds and choices. Takes effect on the next
  /// sample.
  void setGamepadConfig(GamepadConfig config) {
    _config = _config.copyWith(gamepad: config);
  }

  /// Applies [mapping] to both hands from the next sample on.
  void setAxisMapping(AxisMapping mapping) {
    _config = _config.copyWith(axisMapping: mapping);
    _service?.setMapping(mapping);
  }

  /// Applies [fusion] to both hands from the next sample on.
  void setFusion(FusionConfig fusion) {
    _config = _config.copyWith(fusion: fusion);
    _service
      ?..setFilterKind(fusion.kind)
      ..setFilterTuning(fusion.tuning);
  }

  /// Applies [sticks] to both hands from the next sample on.
  void setStickConfig(StickConfig sticks) {
    _config = _config.copyWith(sticks: sticks);
    _service?.setStickConfig(sticks);
  }

  /// Restores a saved rest centre for [hand], before or after connecting.
  void setStickCentre(Hand hand, double x, double y) {
    _stickCentres[hand.wireIndex] = [x, y];
    _service?.setStickCentre(hand.wireIndex, x, y);
  }

  /// Forgets the saved rest centre of [hand].
  void clearStickCentre(Hand hand) {
    _stickCentres[hand.wireIndex] = null;
    _service?.clearStickCentre(hand.wireIndex);
  }

  /// Applies an FF13 calibration to [hand]'s samples when [apply] is true.
  /// Stored until the next connect and re-applied to the new session.
  void setFf13Calibration(
    Hand hand,
    ImuCalibration? calibration, {
    required bool apply,
  }) {
    _calibrations[hand.wireIndex] = (calibration: calibration, apply: apply);
    _service?.setFf13Calibration(
      hand.wireIndex,
      calibration,
      apply: apply && calibration != null,
    );
  }

  /// Takes the current stick position of [hand] as its rest centre.
  void recentreStick(Hand hand) => _service?.recentreStick(hand.wireIndex);

  /// Re-estimates the gyro bias of [hand] from the next stationary second.
  void recalibrate(Hand hand) => _service?.recalibrate(hand.wireIndex);

  /// Resets the view-frame yaw of [hand] without touching pitch and roll.
  void resetYaw(Hand hand) => _service?.resetYaw(hand.wireIndex);

  /// Releases the session, subscriptions and timers and closes the BLE link.
  /// The transport itself is left alone: whoever created it disposes it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _scanSub?.cancel();
    _scanSub = null;
    final deviceId = _deviceId;
    await _disposeSession();
    _deviceId = null;
    _bridge = null;
    _state = WmrConnectionState.idle;
    if (deviceId != null) {
      try {
        await _transport.disconnect(deviceId);
      } catch (_) {
        // Disposal is best-effort: a link that already dropped needs no
        // further error surfaced to a caller that is tearing down.
      }
    }
    await _bridges.close();
    await _connection.close();
    await _controllers.close();
    await _gamepad.close();
    await _link.close();
    await _failures.close();
  }

  ControllerService _createService(String deviceId) {
    final service = ControllerService(
      _transport,
      deviceId,
      mode: _config.streamMode,
      mapping: _config.axisMapping,
      filterKind: _config.fusion.kind,
      filterTuning: _config.fusion.tuning,
      stickConfig: _config.sticks,
      // Record every learned or recentred value before forwarding it to the
      // host. A facade reconnect builds a new service from _stickCentres, so
      // a host that only persists the callback value would otherwise get the
      // old centre back.
      onStickCentre: (hand, centre) {
        final h = Hand.of(hand);
        _stickCentres[h.wireIndex] = List<double>.unmodifiable(centre);
        onStickCentre?.call(h, List.unmodifiable(centre));
      },
    );
    for (var h = 0; h < _stickCentres.length; h++) {
      final centre = _stickCentres[h];
      if (centre == null) {
        service.clearStickCentre(h);
      } else {
        service.setStickCentre(h, centre[0], centre[1]);
      }
      final calibration = _calibrations[h];
      service.setFf13Calibration(
        h,
        calibration.calibration,
        apply: calibration.apply && calibration.calibration != null,
      );
    }
    return service;
  }

  void _subscribeToService(ControllerService service) {
    _frameSub = service.frames.listen((frame) => _onFrame(service, frame));
    _sampleSub = service.decodedSamples.listen(
      (sample) => _onSample(service, sample),
    );
    _modeSub = service.modeChanges.listen((mode) => _onModeChange(mode));
  }

  void _onFrame(ControllerService service, ReceivedFrame frame) {
    if (!identical(service, _service)) return;
    final hand = Hand.of(frame.frame.hand);
    final raw = service.stats.hands[frame.frame.hand];
    if (_controllers.isClosed) return;
    _controllers.add(
      WmrControllerUpdate(
        hand: hand,
        receivedAtUs: frame.receivedAtUs,
        frame: frame.frame,
        stats: WmrHandStats(
          frames: raw.frames,
          incompleteFrames: raw.incomplete,
          lastSequence: raw.lastSequence,
          sequenceGaps: raw.gaps,
          outOfOrder: raw.outOfOrder,
        ),
      ),
    );
  }

  void _onSample(ControllerService service, DecodedSample sample) {
    if (!identical(service, _service)) return;
    final hand = Hand.of(sample.record.hand);
    final input = HandInput.fromSample(sample);
    _latestInputs[hand.wireIndex] = input;
    final decoded = service.decodedStats.hands[sample.record.hand];
    if (!_controllers.isClosed) {
      _controllers.add(
        WmrControllerUpdate(
          hand: hand,
          receivedAtUs: sample.receivedAtUs,
          decoded: sample.record,
          orientation: sample.orientation,
          input: input,
          stats: WmrHandStats(
            records: decoded.records,
            rateHz: decoded.rateHz,
            lastSequence: decoded.lastSequence,
            sequenceGaps: decoded.sequenceGaps,
            outOfOrder: decoded.outOfOrder,
            missingFromTicks: decoded.missingFromTicks,
            periodTicks: decoded.periodTicks,
            dt: decoded.dt,
            windowLoss: decoded.windowLoss,
          ),
        ),
      );
    }
    final gamepad = mapGamepad(
      _latestInputs[0],
      _latestInputs[1],
      _config.gamepad,
      previous: _previousGamepad,
    );
    _previousGamepad = gamepad;
    if (!_gamepad.isClosed) _gamepad.add(gamepad);
  }

  void _onModeChange(ModeState mode) {
    final fault = mode.fault;
    if (fault == null) {
      _reportedFault = null;
    } else {
      final key = '${fault.kind}|${fault.message}';
      if (key != _reportedFault) {
        _reportedFault = key;
        _failures.add(_streamModeException(fault));
      }
    }
    _emitLink();
  }

  void _watchConnection(String deviceId) {
    _linkUp = false;
    _connectionSub = _transport.connectionState(deviceId).listen((state) {
      if (state == BleConnectionState.connected) {
        _linkUp = true;
        return;
      }
      if (state == BleConnectionState.disconnected &&
          _linkUp &&
          !_intentionalDisconnect &&
          !_disposed) {
        _linkUp = false;
        _onUnexpectedDisconnect();
      }
    });
  }

  void _onUnexpectedDisconnect() {
    _linkTimer?.cancel();
    _linkTimer = null;
    _lastStats = null;
    _lastInfo = null;
    _protocol = null;
    if (!_config.autoReconnect) {
      _setState(WmrConnectionState.failed);
      return;
    }
    _setState(WmrConnectionState.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      const Duration(milliseconds: 500),
      _attemptReconnect,
    );
  }

  Future<void> _attemptReconnect() async {
    final bridge = _bridge;
    if (_disposed || bridge == null) return;
    try {
      await connect(bridge);
    } catch (_) {
      // connect already published the typed failure and state.
    }
  }

  void _startLinkPolling() {
    _linkTimer?.cancel();
    _linkTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshLink(),
    );
    _refreshLink();
  }

  Future<void> _refreshLink() async {
    final service = _service;
    final deviceId = _deviceId;
    if (_refreshingLink || service == null || deviceId == null || _disposed) {
      return;
    }
    _refreshingLink = true;
    try {
      if (_state == WmrConnectionState.ready) {
        try {
          _lastInfo = await _transport.connectionInfo(deviceId);
        } catch (_) {
          // The platform may not expose MTU/RSSI; keep the last known values.
        }
        _lastStats = service.decodedStats;
      }
    } finally {
      _refreshingLink = false;
    }
    _emitLink();
  }

  /// Reads the FF16 firmware version and the GATT feature matrix once.
  ///
  /// Best-effort by design: discovery failure leaves [protocol] null, a
  /// missing FF16 is an older bridge, and a malformed value is flagged rather
  /// than thrown. No path here reaches [failures] or blocks the stream.
  Future<void> _readProtocol(ControllerService service) async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    final WmrBridgeFeatures features;
    try {
      final services = await _transport.discoverServices(deviceId);
      var characteristicUuids = const <String>[];
      for (final discovered in services) {
        if (discovered.uuid.toLowerCase() == wmrBridgeServiceUuid) {
          characteristicUuids = discovered.characteristicUuids;
          break;
        }
      }
      features = WmrBridgeFeatures.fromCharacteristics(characteristicUuids);
    } catch (_) {
      // GATT discovery is optional for streaming; leave protocol unknown.
      return;
    }
    if (_disposed || !identical(service, _service)) return;

    WmrProtocolVersion protocol;
    if (features.firmwareVersion) {
      Uint8List? value;
      try {
        value = await _transport.read(
          deviceId,
          wmrBridgeServiceUuid,
          wmrBridgeVersionCharUuid,
        );
      } catch (_) {
        // A read that fails is the same status as a missing FF16: no version.
        value = null;
      }
      if (_disposed || !identical(service, _service)) return;
      protocol = WmrProtocolVersion.parseFirmwareVersion(
        value,
        features: features,
      );
    } else {
      protocol = WmrProtocolVersion.withoutFirmwareVersion(features: features);
    }
    _protocol = protocol;
    _emitLink();
  }

  void _emitLink() {
    if (_link.isClosed) return;
    final service = _service;
    _link.add(
      WmrLinkSnapshot(
        state: _state,
        deviceId: _deviceId,
        mtu: _lastInfo?.mtu,
        rssi: _lastInfo?.rssi,
        connectionIntervalUs: _lastInfo?.connectionIntervalUs,
        phy: _lastInfo?.phy,
        mode: service?.mode ?? _config.streamMode,
        fault: service == null ? null : _faultOf(service.fault),
        stats: _lastStats,
        protocol: _protocol,
      ),
    );
  }

  WmrStreamModeException _reportFault(ModeFault fault) {
    final exception = _streamModeException(fault);
    _reportedFault = '${fault.kind}|${fault.message}';
    _failures.add(exception);
    _emitLink();
    return exception;
  }

  WmrStreamModeException _streamModeException(ModeFault fault) =>
      WmrStreamModeException(fault.message, switch (fault.kind) {
        ModeFaultKind.otherStreamActive =>
          WmrStreamModeFaultKind.otherStreamActive,
        ModeFaultKind.enableFailed => WmrStreamModeFaultKind.enableFailed,
        ModeFaultKind.disableFailed => WmrStreamModeFaultKind.disableFailed,
        ModeFaultKind.mtuTooSmall => WmrStreamModeFaultKind.mtuTooSmall,
      });

  WmrStreamModeFault? _faultOf(ModeFault? fault) => fault == null
      ? null
      : WmrStreamModeFault(switch (fault.kind) {
          ModeFaultKind.otherStreamActive =>
            WmrStreamModeFaultKind.otherStreamActive,
          ModeFaultKind.enableFailed => WmrStreamModeFaultKind.enableFailed,
          ModeFaultKind.disableFailed => WmrStreamModeFaultKind.disableFailed,
          ModeFaultKind.mtuTooSmall => WmrStreamModeFaultKind.mtuTooSmall,
        }, fault.message);

  void _setState(WmrConnectionState next) {
    _state = next;
    if (!_connection.isClosed) _connection.add(next);
    _emitLink();
  }

  Future<void> _disposeSession() async {
    _linkTimer?.cancel();
    _linkTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    await _frameSub?.cancel();
    _frameSub = null;
    await _sampleSub?.cancel();
    _sampleSub = null;
    await _modeSub?.cancel();
    _modeSub = null;
    final service = _service;
    _service = null;
    _latestInputs[0] = null;
    _latestInputs[1] = null;
    _previousGamepad = null;
    _lastInfo = null;
    _lastStats = null;
    _protocol = null;
    _linkUp = false;
    if (service != null) await service.dispose();
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('WmrCompanion has been disposed');
  }
}
