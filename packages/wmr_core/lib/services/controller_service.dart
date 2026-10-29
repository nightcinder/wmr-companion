import 'dart:async';
import 'dart:typed_data';

import '../ble/ble_transport.dart';
import '../domain/axis_mapping.dart';
import '../domain/hand_pipeline.dart';
import '../domain/imu_calibration.dart';
import '../domain/loss_window.dart';
import '../domain/stick_centre.dart';
import '../domain/tick_timer.dart';
import '../protocol/decoded_batch.dart';
import '../protocol/decoded_record.dart';
import '../protocol/firmware_version.dart';
import '../protocol/gatt.dart';
import '../protocol/wmr_fragment.dart';

/// A reassembled frame with the phone-side receive time of its last fragment.
class ReceivedFrame {
  const ReceivedFrame(this.frame, this.receivedAtUs, {this.bridgeId = ''});

  final WmrFrame frame;
  final int receivedAtUs;

  /// Transport device id of the bridge this frame arrived from. Empty only
  /// when a caller built the frame without an attributed bridge (tests or
  /// synthetic data); [ControllerService] always fills it.
  final String bridgeId;
}

/// Per-hand stream counters. Gaps come from the ESP32 sequence numbers only.
class HandStats {
  const HandStats({
    this.bridgeId,
    this.frames = 0,
    this.incomplete = 0,
    this.lastSequence,
    this.gaps = 0,
    this.outOfOrder = 0,
  });

  /// Transport device id of the bridge these figures belong to. Null on the
  /// merged hand view; set on every [StreamStats.byBridge] entry.
  final String? bridgeId;

  final int frames;
  final int incomplete;
  final int? lastSequence;

  /// Frames missing between consecutive received sequence numbers.
  final int gaps;

  /// Received sequence numbers not greater than the previous one (duplicates,
  /// reordering, or an ESP32 reboot).
  final int outOfOrder;

  /// Sequence gaps as a share of expected frames, 0 when nothing arrived.
  double get sequenceLoss {
    final total = frames + gaps;
    return total == 0 ? 0 : gaps / total;
  }
}

class StreamStats {
  const StreamStats({
    required this.hands,
    this.errors = 0,
    this.byBridge = const {},
  });

  final List<HandStats> hands;
  final int errors;

  /// The same figures per bridge, keyed by transport device id. Each entry is
  /// a plain [StreamStats] whose own [byBridge] is empty.
  final Map<String, StreamStats> byBridge;

  /// The figures of one bridge, or null when it is not connected.
  StreamStats? forBridge(String bridgeId) => byBridge[bridgeId];
}

/// Which bridge characteristic the app listens to. Only one at a time.
enum StreamMode {
  /// No bridge stream: FF11, FF12 and FF14 are all off. FF15 (echo) is
  /// independent and still works. The latency screen uses this for the
  /// no-stream run; other screens keep one of the three streams on.
  none,

  /// FF11: raw fragmented frames (Capture needs this).
  raw,

  /// FF12: decoded 56-byte records (orientation needs this).
  decoded,

  /// FF14: the same FF12 records, several per notification.
  batched;

  /// FF12 and FF14 both deliver decoded records to the same pipeline.
  bool get carriesRecords =>
      this == StreamMode.decoded || this == StreamMode.batched;

  /// The characteristic to subscribe to; null for [StreamMode.none].
  String? get characteristicUuid => switch (this) {
    StreamMode.none => null,
    StreamMode.raw => wmrBridgeStreamCharUuid,
    StreamMode.decoded => wmrBridgeDecodedCharUuid,
    StreamMode.batched => wmrBridgeBatchedCharUuid,
  };
}

enum ModeFaultKind {
  /// ATT 0x80: the bridge says another stream is still enabled.
  otherStreamActive,
  enableFailed,
  disableFailed,

  /// Negotiated ATT MTU below 59 (FF12) or 61 (FF14): the bridge sends
  /// nothing on that stream.
  mtuTooSmall,
}

class ModeFault {
  const ModeFault(this.kind, this.message);

  final ModeFaultKind kind;
  final String message;
}

/// What the app asked for and what went wrong with it.
class ModeState {
  const ModeState(this.mode, {this.fault});

  final StreamMode mode;
  final ModeFault? fault;
}

/// Per-hand numbers for the decoded stream.
class DecodedHandStats {
  const DecodedHandStats({
    this.bridgeId,
    this.records = 0,
    this.rateHz = 0,
    this.lastSequence,
    this.sequenceGaps = 0,
    this.outOfOrder = 0,
    this.missingFromTicks = 0,
    this.periodTicks,
    this.dt = const DtStats(),
    this.tickClockRatio,
    this.discontinuities = 0,
    this.largeDtSkips = 0,
    this.nonFiniteSkips = 0,
    this.biasCalibrated = false,
    this.biasProgress = 0,
    this.bias = const [0, 0, 0],
    this.calibratedFlagged = 0,
    this.stickCentre = const [0, 0],
    this.stickLearned = false,
    this.stickCentreUpdates = 0,
    this.stick = const [0, 0],
    this.windowLoss,
  });

  /// Transport device id of the bridge these figures belong to. Null on the
  /// merged hand view; set on every [DecodedStats.byBridge] entry.
  final String? bridgeId;

  final int records;

  /// Records per second over the last second or so, by phone arrival time.
  final double rateHz;
  final int? lastSequence;

  /// Reports the ESP32 numbered but never sent (sequence gaps).
  final int sequenceGaps;
  final int outOfOrder;

  /// Reports missing according to the controller's own tick deltas. Includes
  /// reports lost before the ESP32 saw them, so it is usually larger than
  /// [sequenceGaps].
  final int missingFromTicks;
  final int? periodTicks;
  final DtStats dt;

  /// Controller time over ESP32 time; about 1.0 if the 100 ns unit is right.
  final double? tickClockRatio;
  final int discontinuities;
  final int largeDtSkips;
  final int nonFiniteSkips;
  final bool biasCalibrated;
  final double biasProgress;

  /// Gyro bias in sensor axes, rad/s.
  final List<double> bias;

  /// Records that had the CALIBRATED flag set (version 1 never sets it).
  final int calibratedFlagged;

  /// Stick rest centre, fraction of full scale (raw axes); zero until set.
  final List<double> stickCentre;

  /// Whether [stickCentre] was learned or set by hand.
  final bool stickLearned;
  final int stickCentreUpdates;

  /// Last normalized stick output (x, y).
  final List<double> stick;

  /// Received and missing reports over the trailing five seconds, or null
  /// before the window has filled or while the stream is stale. The
  /// cumulative figure is [missingFromTicks] over [records] +
  /// [missingFromTicks].
  final LossWindowStats? windowLoss;

  /// Reports estimated missing as a share of expected reports, 0 when
  /// nothing was expected yet. Double arithmetic keeps the addition safe at
  /// the integer limit.
  double get cumulativeLoss {
    final received = records.toDouble();
    final lost = missingFromTicks.toDouble();
    final expected = received + lost;
    return expected == 0 ? 0 : lost / expected;
  }

  /// Sequence gaps as a share of expected records, 0 when nothing arrived.
  double get sequenceLoss {
    final total = records + sequenceGaps;
    return total == 0 ? 0 : sequenceGaps / total;
  }
}

class DecodedStats {
  const DecodedStats({
    required this.hands,
    this.wrongLength = 0,
    this.unknownVersion = 0,
    this.badHand = 0,
    this.batches = 0,
    this.batchRecords = 0,
    this.batchMax = 0,
    this.batchErrors = 0,
    this.byBridge = const {},
  });

  final List<DecodedHandStats> hands;

  /// The same figures per bridge, keyed by transport device id. Each entry is
  /// a plain [DecodedStats] whose own [byBridge] is empty. Per-bridge entries
  /// measure that bridge's records: rate, sequence gaps, timing and loss.
  /// Fusion state (bias, stick, skipped-update counters) stays on the merged
  /// hand view, which is per hand by definition.
  final Map<String, DecodedStats> byBridge;

  /// The figures of one bridge, or null when it is not connected.
  DecodedStats? forBridge(String bridgeId) => byBridge[bridgeId];

  /// Record errors, FF12 and FF14 alike.
  final int wrongLength;
  final int unknownVersion;
  final int badHand;

  /// FF14 notifications that parsed, and the records they carried (good or
  /// not). Zero on FF12.
  final int batches;
  final int batchRecords;

  /// Most records seen in one batch.
  final int batchMax;

  /// FF14 notifications rejected as a whole (header or length wrong).
  final int batchErrors;

  /// Records per batch, or null before the first batch.
  double? get batchMean => batches == 0 ? null : batchRecords / batches;

  int get parseErrors => wrongLength + unknownVersion + badHand + batchErrors;
}

/// One bridge's link and its stream rate and loss, per hand.
///
/// The bridge id is the transport device id. [rateHz] and [loss] are in wire
/// hand order (0 LEFT, 1 RIGHT); a hand the bridge does not feed has a zero
/// rate and a null loss. [loss] is tick loss on the decoded streams and
/// sequence loss on the raw stream, so different bridges on different streams
/// are not compared with the same definition.
class BridgeLinkSnapshot {
  const BridgeLinkSnapshot({
    required this.bridgeId,
    required this.mode,
    this.mtu,
    this.rssi,
    this.connectionIntervalUs,
    this.phy,
    this.rateHz = const [0, 0],
    this.loss = const [null, null],
    this.protocol,
    this.protocolUnavailable = false,
  });

  final String bridgeId;

  /// The stream the service listens to on every bridge.
  final StreamMode mode;

  /// Link parameters, null where the platform does not expose them.
  final int? mtu;
  final int? rssi;
  final int? connectionIntervalUs;
  final String? phy;

  /// Per-hand records (decoded) or frames (raw) per second.
  final List<double> rateHz;

  /// Per-hand loss, or null for a hand this bridge has not fed yet.
  final List<double?> loss;

  /// The bridge's FF16 firmware version and FF11-FF16 feature matrix, null
  /// until the one-time post-connect read finishes and when discovery failed.
  final WmrProtocolVersion? protocol;

  /// True when discovery failed or the bridge exposed no FF10 service, so
  /// [protocol] will stay null: the read will never land. False while the
  /// first read is still in flight and once it has produced a result.
  final bool protocolUnavailable;

  /// Total rate over both hands.
  double get totalRateHz => rateHz.fold(0, (sum, rate) => sum + rate);

  /// The worse of the measured hand losses, or null when neither is known.
  double? get worstLoss {
    double? worst;
    for (final l in loss) {
      if (l != null && (worst == null || l > worst)) worst = l;
    }
    return worst;
  }
}

/// Records per second over a sliding window of about a second.
class _RateMeter {
  int? _startUs;
  int _count = 0;
  int _lastUs = 0;
  double _rate = 0;

  void add(int nowUs) {
    _lastUs = nowUs;
    final start = _startUs ??= nowUs;
    _count++;
    final elapsed = nowUs - start;
    if (elapsed >= 1000000) {
      _rate = _count * 1000000 / elapsed;
      _startUs = nowUs;
      _count = 0;
    }
  }

  /// 0 when nothing arrived for 2 s.
  double rate(int nowUs) => nowUs - _lastUs > 2000000 ? 0 : _rate;
}

/// Raw-stream counters of one bridge. Reassembly is per bridge, so fragments
/// from two links cannot be mixed into the same frame.
class _RawBridgeState {
  _RawBridgeState(this.bridgeId);

  final String bridgeId;
  final WmrReassembler reassembler = WmrReassembler();
  final List<int?> lastSeq = List.filled(wmrNumControllers, null);
  final List<int> gaps = List.filled(wmrNumControllers, 0);
  final List<int> outOfOrder = List.filled(wmrNumControllers, 0);
  final List<_RateMeter> rates = [
    for (var h = 0; h < wmrNumControllers; h++) _RateMeter(),
  ];

  /// A new subscription starts a new sequence baseline, as the bridge's
  /// sequence keeps advancing while no stream is enabled.
  void streamRestarted() => lastSeq.fillRange(0, lastSeq.length, null);

  double rateHz(int hand, int nowUs) => rates[hand].rate(nowUs);

  double? loss(int hand) {
    final received = reassembler.framesComplete[hand];
    final lost = gaps[hand];
    final total = received + lost;
    return total == 0 ? null : lost / total;
  }
}

/// Decoded-stream counters of one bridge. Timing and loss are tracked per
/// bridge as well as merged, so a bridge that drops records does not hide
/// behind the other one's pipeline.
class _DecodedBridgeState {
  _DecodedBridgeState(this.bridgeId);

  final String bridgeId;
  final List<int?> lastSeq = List.filled(wmrNumControllers, null);
  final List<int> gaps = List.filled(wmrNumControllers, 0);
  final List<int> outOfOrder = List.filled(wmrNumControllers, 0);
  final List<int> records = List.filled(wmrNumControllers, 0);
  final List<_RateMeter> rates = [
    for (var h = 0; h < wmrNumControllers; h++) _RateMeter(),
  ];
  final List<TickTimer> timers = [
    for (var h = 0; h < wmrNumControllers; h++) TickTimer(),
  ];
  final List<LossWindow> lossWindows = [
    for (var h = 0; h < wmrNumControllers; h++) LossWindow(),
  ];

  // Parse counters, FF12 and FF14 alike.
  int wrongLength = 0;
  int unknownVersion = 0;
  int badHand = 0;
  int batches = 0;
  int batchRecords = 0;
  int batchMax = 0;
  int batchErrors = 0;

  void streamRestarted() {
    lastSeq.fillRange(0, lastSeq.length, null);
    for (final t in timers) {
      t.rebaseline();
    }
    for (final w in lossWindows) {
      w.reset();
    }
  }

  double rateHz(int hand, int nowUs) => rates[hand].rate(nowUs);

  double? tickLoss(int hand) {
    final received = records[hand];
    final lost = timers[hand].missing;
    final total = received + lost;
    return total == 0 ? null : lost / total;
  }

  double? sequenceLoss(int hand) {
    final total = records[hand] + gaps[hand];
    return total == 0 ? null : gaps[hand] / total;
  }
}

/// Subscribes to the bridge stream and turns it into frames (FF11) or fused
/// samples (FF12 and FF14).
class ControllerService {
  ControllerService(
    this.transport,
    Object deviceIdOrIds, {
    this._mode = StreamMode.raw,
    this._mapping = AxisMapping.defaultMapping,
    this._filterKind = FilterKind.madgwick,
    this._filterTuning = const FilterTuning(),
    StickConfig stickConfig = const StickConfig(),
    this.onStickCentre,
  }) : _deviceIds = {
         if (deviceIdOrIds is Iterable<String>)
           ...deviceIdOrIds
         else if (deviceIdOrIds is String)
           deviceIdOrIds,
       }.toList(),
       _stickConfig = stickConfig {
    _pipelines = [
      for (var h = 0; h < wmrNumControllers; h++)
        HandPipeline(
          stickNormalizer: StickNormalizer(
            onCentreChanged: onStickCentre == null
                ? null
                : (centre) => onStickCentre!(h, centre),
          ),
        ),
    ];
    for (final p in _pipelines) {
      p.mapping = _mapping;
      p.setFilter(_filterKind);
      p.tuning = _filterTuning;
      p.stickConfig = stickConfig;
    }
  }

  /// Called when a hand learns a new rest centre or the user re-centres it,
  /// so the app can save it. Restoring a saved centre does not call it.
  final void Function(int hand, List<double> centre)? onStickCentre;

  final BleTransport transport;
  final List<String> _deviceIds;

  List<String> get deviceIds => List.unmodifiable(_deviceIds);
  String get deviceId => _deviceIds.isNotEmpty ? _deviceIds.first : '';

  /// Raw and decoded counters per bridge, keyed by transport device id.
  final Map<String, _RawBridgeState> _rawBridges = {};
  final Map<String, _DecodedBridgeState> _decodedBridges = {};

  /// FF16 firmware version and feature matrix, keyed by transport device id.
  final Map<String, WmrProtocolVersion> _protocols = {};

  /// Bridges whose protocol discovery failed, so no read will land. A later
  /// read clears the id and publishes a result.
  final Set<String> _protocolUnavailable = {};
  final StreamController<Map<String, WmrProtocolVersion>> _protocolChanges =
      StreamController.broadcast();

  // Merged per-hand counters, across every bridge (the fused view). They are
  // kept separately from the per-bridge states so removing a bridge does not
  // rewrite the history the merged view already showed.
  final List<int?> _lastSeq = List.filled(wmrNumControllers, null);
  final List<int> _gaps = List.filled(wmrNumControllers, 0);
  final List<int> _outOfOrder = List.filled(wmrNumControllers, 0);
  final List<int> _rawFrames = List.filled(wmrNumControllers, 0);
  final List<int> _rawIncomplete = List.filled(wmrNumControllers, 0);
  int _rawErrors = 0;
  final StreamController<ReceivedFrame> _frames = StreamController.broadcast();
  final Map<String, StreamSubscription<BleNotification>> _subscriptions = {};

  // Decoded (FF12 and FF14) side.
  late final List<HandPipeline> _pipelines;
  final List<int?> _dLastSeq = List.filled(wmrNumControllers, null);
  final List<int> _dGaps = List.filled(wmrNumControllers, 0);
  final List<int> _dOutOfOrder = List.filled(wmrNumControllers, 0);
  final List<int> _dRecords = List.filled(wmrNumControllers, 0);
  final List<LossWindow> _lossWindows = [
    for (var h = 0; h < wmrNumControllers; h++) LossWindow(),
  ];
  final List<_RateMeter> _rates = [
    for (var h = 0; h < wmrNumControllers; h++) _RateMeter(),
  ];
  int _wrongLength = 0;
  int _unknownVersion = 0;
  int _badHand = 0;
  int _batches = 0;
  int _batchRecords = 0;
  int _batchMax = 0;
  int _batchErrors = 0;
  final List<String?> _lastDeviceForHand = List.filled(wmrNumControllers, null);
  final StreamController<DecodedSample> _samples = StreamController.broadcast();
  final StreamController<String> _deviceRemovals = StreamController.broadcast();

  StreamMode _mode;
  ModeFault? _fault;
  AxisMapping _mapping;
  FilterKind _filterKind;
  FilterTuning _filterTuning;
  StickConfig _stickConfig;
  final List<List<double>> _lastStick = [
    for (var h = 0; h < wmrNumControllers; h++) const [0.0, 0.0],
  ];
  final StreamController<ModeState> _modeChanges = StreamController.broadcast();
  bool _started = false;

  Stream<ReceivedFrame> get frames => _frames.stream;

  /// Every decoded sample, both hands, after timing and fusion.
  Stream<DecodedSample> get decodedSamples => _samples.stream;

  /// Decoded samples of one hand.
  Stream<DecodedSample> samplesFor(int hand) =>
      _samples.stream.where((s) => s.record.hand == hand);

  /// Emits a bridge id when [removeDevice] removes it.
  ///
  /// Consumers that share [decodedSamples] use this to tell which hand just
  /// lost its source, so they can release that hand without stopping the
  /// other one.
  Stream<String> get deviceRemovals => _deviceRemovals.stream;

  /// The FF16 firmware version and GATT feature matrix of one bridge, or null
  /// while the one-time read after connect has not finished and when
  /// discovery failed. A bridge without FF16 reports
  /// [WmrProtocolVersion.withoutFirmwareVersion].
  WmrProtocolVersion? protocolFor(String bridgeId) => _protocols[bridgeId];

  /// Emits the per-bridge protocol map whenever a read or a removal changes
  /// it.
  Stream<Map<String, WmrProtocolVersion>> get protocolChanges =>
      _protocolChanges.stream;

  StreamMode get mode => _mode;
  ModeFault? get fault => _fault;
  ModeState get modeState => ModeState(_mode, fault: _fault);

  /// Emits whenever the requested mode or its fault changes.
  Stream<ModeState> get modeChanges => _modeChanges.stream;

  AxisMapping get mapping => _mapping;
  FilterKind get filterKind => _filterKind;
  FilterTuning get filterTuning => _filterTuning;

  HandPipeline pipeline(int hand) => _pipelines[hand];

  _RawBridgeState _rawBridge(String bridgeId) =>
      _rawBridges.putIfAbsent(bridgeId, () => _RawBridgeState(bridgeId));

  _DecodedBridgeState _decodedBridge(String bridgeId) => _decodedBridges
      .putIfAbsent(bridgeId, () => _DecodedBridgeState(bridgeId));

  /// Connects and subscribes to the current [mode]. Call again after every
  /// reconnect: the bridge forgets the subscription on disconnect, and the
  /// wanted stream is enabled from scratch. [StreamMode.none] connects
  /// without enabling a stream.
  bool _starting = false;

  /// Connects and subscribes to the current [mode]. Call again after every
  /// reconnect: the bridge forgets the subscription on disconnect, and the
  /// wanted stream is enabled from scratch. [StreamMode.none] connects
  /// without enabling a stream.
  Future<void> start() async {
    _starting = true;
    try {
      final toConnect = List.of(_deviceIds);
      for (final id in toConnect) {
        await transport.connect(id);
      }
      _started = true;
      if (_mode == StreamMode.none) {
        _readProtocols();
        return;
      }
      await _subscribe();
      _readProtocols();
    } finally {
      _starting = false;
    }
  }

  /// Reads FF16 and the feature matrix once per connected bridge.
  ///
  /// Best-effort and never awaited by a caller: a slow or failed read must not
  /// delay the stream or connect. A missing FF16 is an older bridge, not an
  /// error; a malformed value is flagged on the snapshot.
  void _readProtocols() {
    for (final id in _deviceIds) {
      _protocolUnavailable.remove(id);
      unawaited(_readProtocol(id));
    }
  }

  Future<void> _readProtocol(String bridgeId) async {
    final WmrBridgeFeatures features;
    try {
      final services = await transport.discoverServices(bridgeId);
      var foundService = false;
      var characteristicUuids = const <String>[];
      for (final discovered in services) {
        if (discovered.uuid.toLowerCase() == wmrBridgeServiceUuid) {
          foundService = true;
          characteristicUuids = discovered.characteristicUuids;
          break;
        }
      }
      if (!foundService) {
        // A bridge without FF10 is not a WMR bridge: leave it unknown rather
        // than claiming an empty capability set.
        if (_deviceIds.contains(bridgeId)) _markProtocolUnavailable(bridgeId);
        return;
      }
      features = WmrBridgeFeatures.fromCharacteristics(characteristicUuids);
    } catch (_) {
      // Discovery is optional for streaming; leave the protocol unknown.
      if (_deviceIds.contains(bridgeId)) _markProtocolUnavailable(bridgeId);
      return;
    }
    if (!_deviceIds.contains(bridgeId)) return;
    _protocolUnavailable.remove(bridgeId);

    WmrProtocolVersion protocol;
    if (features.firmwareVersion) {
      Uint8List? value;
      try {
        value = await transport.read(
          bridgeId,
          wmrBridgeServiceUuid,
          wmrBridgeVersionCharUuid,
        );
      } catch (_) {
        // A failed read is the same status as a missing FF16: no version.
        value = null;
      }
      if (!_deviceIds.contains(bridgeId)) return;
      protocol = WmrProtocolVersion.parseFirmwareVersion(
        value,
        features: features,
      );
    } else {
      protocol = WmrProtocolVersion.withoutFirmwareVersion(features: features);
    }
    _protocols[bridgeId] = protocol;
    _emitProtocols();
  }

  void _emitProtocols() {
    if (!_protocolChanges.isClosed) {
      _protocolChanges.add(Map.unmodifiable(_protocols));
    }
  }

  void _markProtocolUnavailable(String bridgeId) {
    if (_protocolUnavailable.add(bridgeId)) _emitProtocols();
  }

  /// Connects and subscribes [deviceId] to the active stream.
  Future<void> addDevice(String deviceId) async {
    if (!_deviceIds.contains(deviceId)) {
      _deviceIds.add(deviceId);
    }
    if (_started || _starting) {
      try {
        await transport.connect(deviceId);
        if (_mode != StreamMode.none) {
          final oldSub = _subscriptions.remove(deviceId);
          await oldSub?.cancel();
          _subscribeDevice(deviceId);
          if (_mode.carriesRecords) {
            await _checkMtu(deviceId);
          }
          _emitMode();
        }
        _protocolUnavailable.remove(deviceId);
        unawaited(_readProtocol(deviceId));
      } catch (_) {
        _deviceIds.remove(deviceId);
        final sub = _subscriptions.remove(deviceId);
        await sub?.cancel();
        rethrow;
      }
    }
  }

  /// Unsubscribes and optionally disconnects [deviceId].
  Future<void> removeDevice(
    String deviceId, {
    bool disconnectTransport = true,
  }) async {
    if (!_deviceIds.contains(deviceId)) return;
    _deviceIds.remove(deviceId);
    _rawBridges.remove(deviceId);
    _decodedBridges.remove(deviceId);
    _protocolUnavailable.remove(deviceId);
    if (_protocols.remove(deviceId) != null) _emitProtocols();
    final sub = _subscriptions.remove(deviceId);
    await sub?.cancel();
    for (var h = 0; h < wmrNumControllers; h++) {
      if (_lastDeviceForHand[h] == deviceId) {
        _resetHandBaseline(h);
      }
    }
    if (!_deviceRemovals.isClosed) _deviceRemovals.add(deviceId);
    if (disconnectTransport) {
      await transport.disconnect(deviceId);
    }
  }

  /// Switches to [next]. The transport writes 0x0000 to the active
  /// characteristic's CCC before it enables the other one; a refusal
  /// (ATT 0x80) lands in [fault]. [StreamMode.none] turns the active stream
  /// off and enables nothing.
  Future<void> setMode(StreamMode next) async {
    if (next == _mode && _fault == null) return;
    final previous = _mode;
    _mode = next;
    _fault = null;
    _emitMode();
    if (!_started) return;
    if (next == StreamMode.none) {
      await _disableStream(previous);
      return;
    }
    await _subscribe();
  }

  /// Turns [previous] off through the transport. Its CCC write is the same
  /// one a switch uses; the UI never writes CCCDs itself.
  Future<void> _disableStream(StreamMode previous) async {
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
    final uuid = previous.characteristicUuid;
    if (uuid == null) {
      _emitMode();
      return;
    }
    for (final id in _deviceIds) {
      try {
        await transport.unsubscribe(id, wmrBridgeServiceUuid, uuid);
      } catch (e) {
        _fault = ModeFault(ModeFaultKind.disableFailed, '$e');
      }
    }
    _emitMode();
  }

  Future<void> _subscribe() async {
    final oldSubs = _subscriptions.values.toList();
    _subscriptions.clear();
    for (final s in oldSubs) {
      await s.cancel();
    }
    // Sequence numbers kept advancing while we were away or on the other
    // stream, so the first record of a new subscription is a new baseline,
    // not a gap. The same goes for tick timing.
    _lastSeq.fillRange(0, _lastSeq.length, null);
    _dLastSeq.fillRange(0, _dLastSeq.length, null);
    _lastDeviceForHand.fillRange(0, _lastDeviceForHand.length, null);
    for (final p in _pipelines) {
      p.streamRestarted();
    }
    for (final w in _lossWindows) {
      // The new stream has no five-second history yet.
      w.reset();
    }
    for (final id in _deviceIds) {
      _rawBridge(id).streamRestarted();
      _decodedBridge(id).streamRestarted();
    }
    _fault = null;
    for (final id in _deviceIds) {
      try {
        _subscribeDevice(id);
      } catch (_) {
        // Bridge may be disconnected or link lost; skip to allow remaining bridges to subscribe.
      }
    }
    if (_mode.carriesRecords) {
      for (final id in _deviceIds) {
        try {
          await _checkMtu(id);
        } catch (_) {}
      }
    }
    _emitMode();
  }

  void _resetHandBaseline(int hand) {
    _lastSeq[hand] = null;
    _dLastSeq[hand] = null;
    _lastDeviceForHand[hand] = null;
    _pipelines[hand].streamRestarted();
    _lossWindows[hand].reset();
  }

  void _checkSourceDevice(int hand, String sourceDeviceId) {
    if (_lastDeviceForHand[hand] != null &&
        _lastDeviceForHand[hand] != sourceDeviceId) {
      _resetHandBaseline(hand);
    }
    _lastDeviceForHand[hand] = sourceDeviceId;
  }

  void _subscribeDevice(String id) {
    final uuid = _mode.characteristicUuid;
    if (uuid == null) return;
    _subscriptions[id] = transport
        .subscribe(id, wmrBridgeServiceUuid, uuid)
        .listen(switch (_mode) {
          StreamMode.none => throw StateError('No stream to subscribe to'),
          StreamMode.raw => (n) => _onNotification(n, id),
          StreamMode.decoded => (n) => _onDecoded(n, id),
          StreamMode.batched => (n) => _onBatched(n, id),
        }, onError: _onStreamError);
  }

  Future<void> _checkMtu(String id) async {
    final (name, min) = _mode == StreamMode.batched
        ? ('FF14', wmrBatchedMinMtu)
        : ('FF12', wmrDecodedMinMtu);
    try {
      final mtu = (await transport.connectionInfo(id)).mtu;
      if (mtu != null && mtu < min && _fault == null) {
        _fault = ModeFault(
          ModeFaultKind.mtuTooSmall,
          'ATT MTU is $mtu; $name needs at least $min, so the '
          'bridge sends nothing.',
        );
      }
    } catch (_) {
      // MTU unknown: nothing to warn about.
    }
  }

  void _onStreamError(Object error) {
    final ModeFault fault;
    if (error is BleStreamException) {
      fault = ModeFault(switch (error.kind) {
        BleStreamFaultKind.otherStreamActive => ModeFaultKind.otherStreamActive,
        BleStreamFaultKind.enableFailed => ModeFaultKind.enableFailed,
        BleStreamFaultKind.disableFailed => ModeFaultKind.disableFailed,
      }, error.message);
    } else {
      fault = ModeFault(ModeFaultKind.enableFailed, '$error');
    }
    _fault = fault;
    _emitMode();
  }

  void _emitMode() {
    if (!_modeChanges.isClosed) _modeChanges.add(modeState);
  }

  void _onNotification(BleNotification n, String sourceDeviceId) {
    final bridge = _rawBridge(sourceDeviceId);
    final beforeLeft = bridge.reassembler.framesIncomplete[wmrHandLeft];
    final beforeRight = bridge.reassembler.framesIncomplete[wmrHandRight];
    final beforeErrors = bridge.reassembler.errors;
    final result = bridge.reassembler.push(n.value);
    _rawIncomplete[wmrHandLeft] +=
        bridge.reassembler.framesIncomplete[wmrHandLeft] - beforeLeft;
    _rawIncomplete[wmrHandRight] +=
        bridge.reassembler.framesIncomplete[wmrHandRight] - beforeRight;
    _rawErrors += bridge.reassembler.errors - beforeErrors;
    if (result != ReassemblyResult.frameComplete) return;
    final frame = bridge.reassembler.lastFrame!;
    final hand = frame.hand;
    _rawFrames[hand]++;

    // Per-bridge figures: this bridge's own sequence line.
    final bridgeLast = bridge.lastSeq[hand];
    if (bridgeLast != null) {
      final delta = sequenceDelta(bridgeLast, frame.sequence);
      if (delta > 1) {
        bridge.gaps[hand] += delta - 1;
      } else if (delta <= 0) {
        bridge.outOfOrder[hand]++;
      }
    }
    bridge.lastSeq[hand] = frame.sequence;
    bridge.rates[hand].add(n.receivedAtUs);

    // Merged figures: the pipeline is fused per hand, so a change of source
    // still starts a new baseline.
    _checkSourceDevice(hand, sourceDeviceId);
    final last = _lastSeq[hand];
    if (last != null) {
      final delta = sequenceDelta(last, frame.sequence);
      if (delta > 1) {
        _gaps[hand] += delta - 1;
      } else if (delta <= 0) {
        _outOfOrder[hand]++;
      }
    }
    _lastSeq[hand] = frame.sequence;
    _frames.add(ReceivedFrame(frame, n.receivedAtUs, bridgeId: sourceDeviceId));
  }

  void _onDecoded(BleNotification n, String sourceDeviceId) =>
      _onRecord(parseDecodedRecord(n.value), n.receivedAtUs, sourceDeviceId);

  /// Every record of a batch gets the batch's arrival time. Timing and
  /// fusion use `device_ticks`, so that does not change the time step.
  void _onBatched(BleNotification n, String sourceDeviceId) {
    final parsed = parseDecodedBatch(n.value);
    final bridge = _decodedBridge(sourceDeviceId);
    final records = parsed.records;
    if (records == null) {
      _batchErrors++;
      bridge.batchErrors++;
      return;
    }
    _batches++;
    _batchRecords += records.length;
    bridge.batches++;
    bridge.batchRecords += records.length;
    if (records.length > _batchMax) _batchMax = records.length;
    if (records.length > bridge.batchMax) bridge.batchMax = records.length;
    for (final r in records) {
      _onRecord(r, n.receivedAtUs, sourceDeviceId);
    }
  }

  void _onRecord(
    DecodedParseResult parsed,
    int receivedAtUs,
    String sourceDeviceId,
  ) {
    final r = parsed.record;
    final bridge = _decodedBridge(sourceDeviceId);
    if (r == null) {
      switch (parsed.error!) {
        case DecodedParseError.wrongLength:
          _wrongLength++;
          bridge.wrongLength++;
        case DecodedParseError.unknownVersion:
          _unknownVersion++;
          bridge.unknownVersion++;
        case DecodedParseError.badHand:
          _badHand++;
          bridge.badHand++;
      }
      return;
    }
    final hand = r.hand;

    // Per-bridge figures: this bridge's sequence line, timing and loss.
    final bridgeLast = bridge.lastSeq[hand];
    if (bridgeLast != null) {
      final delta = sequenceDelta(bridgeLast, r.sequence);
      if (delta > 1) {
        bridge.gaps[hand] += delta - 1;
      } else if (delta <= 0) {
        bridge.outOfOrder[hand]++;
      }
    }
    bridge.lastSeq[hand] = r.sequence;
    bridge.records[hand]++;
    bridge.rates[hand].add(receivedAtUs);
    bridge.timers[hand].advance(r.deviceTicks, r.rxTimeUs);
    bridge.lossWindows[hand].add(
      receivedAtUs,
      bridge.records[hand],
      bridge.timers[hand].missing,
    );

    // Merged figures: the fused view stays per hand.
    _checkSourceDevice(hand, sourceDeviceId);
    final last = _dLastSeq[hand];
    if (last != null) {
      final delta = sequenceDelta(last, r.sequence);
      if (delta > 1) {
        _dGaps[hand] += delta - 1;
      } else if (delta <= 0) {
        _dOutOfOrder[hand]++;
      }
    }
    _dLastSeq[hand] = r.sequence;
    _dRecords[hand]++;
    _rates[hand].add(receivedAtUs);
    final sample = _pipelines[hand].add(
      r,
      receivedAtUs,
      bridgeId: sourceDeviceId,
    );
    _lastStick[hand] = sample.stick;
    _lossWindows[hand].add(
      receivedAtUs,
      _dRecords[hand],
      _pipelines[hand].timer.missing,
    );
    _samples.add(sample);
  }

  /// Applies [m] to both hands from the next sample on.
  void setMapping(AxisMapping m) {
    _mapping = m;
    for (final p in _pipelines) {
      p.mapping = m;
    }
  }

  /// Applies [calibration] to [hand]'s samples when [apply] is true, and
  /// clears it otherwise. The pipeline ignores it for CALIBRATED-flagged
  /// records. A null [calibration] is the same as [apply] false: there is
  /// nothing to apply.
  void setFf13Calibration(
    int hand,
    ImuCalibration? calibration, {
    required bool apply,
  }) {
    _pipelines[hand].calibration = apply ? calibration : null;
  }

  /// Applies [c] to both hands from the next sample on.
  void setStickConfig(StickConfig c) {
    _stickConfig = c;
    for (final p in _pipelines) {
      p.stickConfig = c;
    }
  }

  StickConfig get stickConfig => _stickConfig;

  /// Restores a saved rest centre for [hand], in fraction of full scale.
  void setStickCentre(int hand, double cx, double cy) =>
      _pipelines[hand].stickNormalizer.restoreCentre(cx, cy);

  /// Forgets the saved rest centre of [hand].
  void clearStickCentre(int hand) => _pipelines[hand].stickNormalizer.reset();

  /// Takes the current stick position of [hand] as its rest centre.
  void recentreStick(int hand) => _pipelines[hand].recentreStick();

  void setFilterKind(FilterKind k) {
    _filterKind = k;
    for (final p in _pipelines) {
      p.setFilter(k);
    }
  }

  /// Applies [tuning] to both hands from the next sample on. The gain of the
  /// filter that is not selected is kept for when it is next selected.
  void setFilterTuning(FilterTuning tuning) {
    _filterTuning = tuning;
    for (final p in _pipelines) {
      p.tuning = tuning;
    }
  }

  /// Re-estimates the gyro bias of [hand] from the next stationary second.
  void recalibrate(int hand) => _pipelines[hand].recalibrate();

  void resetYaw(int hand) => _pipelines[hand].resetYaw();

  /// Raw (FF11) figures, merged per hand and per bridge.
  StreamStats get stats => StreamStats(
    hands: [
      for (var h = 0; h < wmrNumControllers; h++)
        HandStats(
          frames: _rawFrames[h],
          incomplete: _rawIncomplete[h],
          lastSequence: _lastSeq[h],
          gaps: _gaps[h],
          outOfOrder: _outOfOrder[h],
        ),
    ],
    errors: _rawErrors,
    byBridge: {for (final id in _deviceIds) id: statsForBridge(id)},
  );

  /// Raw figures of one bridge. A bridge that has delivered nothing yet is
  /// all zeroes, not null, so a freshly connected row still renders.
  StreamStats statsForBridge(String bridgeId) {
    final bridge = _rawBridge(bridgeId);
    return StreamStats(
      hands: [
        for (var h = 0; h < wmrNumControllers; h++)
          HandStats(
            bridgeId: bridgeId,
            frames: bridge.reassembler.framesComplete[h],
            incomplete: bridge.reassembler.framesIncomplete[h],
            lastSequence: bridge.lastSeq[h],
            gaps: bridge.gaps[h],
            outOfOrder: bridge.outOfOrder[h],
          ),
      ],
      errors: bridge.reassembler.errors,
    );
  }

  /// Decoded (FF12/FF14) figures, merged per hand and per bridge. The merged
  /// figures keep the fused pipeline's timing and fusion state; a per-bridge
  /// entry measures that bridge's own records and link.
  DecodedStats get decodedStats {
    final now = transport.clock.nowUs;
    return DecodedStats(
      hands: [
        for (var h = 0; h < wmrNumControllers; h++)
          DecodedHandStats(
            records: _dRecords[h],
            rateHz: _rates[h].rate(now),
            lastSequence: _dLastSeq[h],
            sequenceGaps: _dGaps[h],
            outOfOrder: _dOutOfOrder[h],
            missingFromTicks: _pipelines[h].timer.missing,
            periodTicks: _pipelines[h].timer.periodTicks,
            dt: _pipelines[h].timer.dtStats,
            tickClockRatio: _pipelines[h].timer.tickClockRatio,
            discontinuities: _pipelines[h].timer.discontinuities,
            largeDtSkips: _pipelines[h].largeDtSkips,
            nonFiniteSkips: _pipelines[h].nonFiniteSkips,
            biasCalibrated: _pipelines[h].bias.calibrated,
            biasProgress: _pipelines[h].bias.progress,
            bias: _pipelines[h].bias.bias,
            calibratedFlagged: _pipelines[h].calibratedFlagged,
            stickCentre: _pipelines[h].stickNormalizer.centre,
            stickLearned: _pipelines[h].stickNormalizer.hasCentre,
            stickCentreUpdates: _pipelines[h].stickNormalizer.centreUpdates,
            stick: _lastStick[h],
            windowLoss: _lossWindows[h].statsAt(now),
          ),
      ],
      wrongLength: _wrongLength,
      unknownVersion: _unknownVersion,
      badHand: _badHand,
      batches: _batches,
      batchRecords: _batchRecords,
      batchMax: _batchMax,
      batchErrors: _batchErrors,
      byBridge: {for (final id in _deviceIds) id: decodedStatsForBridge(id)},
    );
  }

  /// Decoded figures of one bridge, measured on its own records rather than
  /// on the fused per-hand pipeline.
  DecodedStats decodedStatsForBridge(String bridgeId) {
    final now = transport.clock.nowUs;
    final bridge = _decodedBridge(bridgeId);
    return DecodedStats(
      hands: [
        for (var h = 0; h < wmrNumControllers; h++)
          DecodedHandStats(
            bridgeId: bridgeId,
            records: bridge.records[h],
            rateHz: bridge.rates[h].rate(now),
            lastSequence: bridge.lastSeq[h],
            sequenceGaps: bridge.gaps[h],
            outOfOrder: bridge.outOfOrder[h],
            missingFromTicks: bridge.timers[h].missing,
            periodTicks: bridge.timers[h].periodTicks,
            dt: bridge.timers[h].dtStats,
            tickClockRatio: bridge.timers[h].tickClockRatio,
            discontinuities: bridge.timers[h].discontinuities,
            windowLoss: bridge.lossWindows[h].statsAt(now),
          ),
      ],
      wrongLength: bridge.wrongLength,
      unknownVersion: bridge.unknownVersion,
      badHand: bridge.badHand,
      batches: bridge.batches,
      batchRecords: bridge.batchRecords,
      batchMax: bridge.batchMax,
      batchErrors: bridge.batchErrors,
    );
  }

  /// Link parameters, rate and loss of every connected bridge.
  Future<List<BridgeLinkSnapshot>> bridgeLinks() async => [
    for (final id in _deviceIds) await bridgeLink(id),
  ];

  /// One bridge's link snapshot. Platform link fields are null when the
  /// transport does not expose them or the bridge is not connected.
  Future<BridgeLinkSnapshot> bridgeLink(String bridgeId) async {
    BleConnectionInfo? info;
    try {
      info = await transport.connectionInfo(bridgeId);
    } catch (_) {
      // Not connected, or the platform does not expose the fields.
    }
    final now = transport.clock.nowUs;
    final raw = _rawBridge(bridgeId);
    final decoded = _decodedBridge(bridgeId);
    final records = _mode.carriesRecords;
    return BridgeLinkSnapshot(
      bridgeId: bridgeId,
      mode: _mode,
      mtu: info?.mtu,
      rssi: info?.rssi,
      connectionIntervalUs: info?.connectionIntervalUs,
      phy: info?.phy,
      rateHz: [
        for (var h = 0; h < wmrNumControllers; h++)
          records ? decoded.rateHz(h, now) : raw.rateHz(h, now),
      ],
      loss: [
        for (var h = 0; h < wmrNumControllers; h++)
          records
              ? decoded.tickLoss(h) ?? decoded.sequenceLoss(h)
              : raw.loss(h),
      ],
      protocol: _protocols[bridgeId],
      protocolUnavailable: _protocolUnavailable.contains(bridgeId),
    );
  }

  Future<void> dispose() async {
    final subs = _subscriptions.values.toList();
    _subscriptions.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
    await _frames.close();
    await _samples.close();
    await _modeChanges.close();
    await _deviceRemovals.close();
    await _protocolChanges.close();
  }
}
