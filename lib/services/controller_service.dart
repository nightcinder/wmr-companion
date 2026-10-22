import 'dart:async';

import '../ble/ble_transport.dart';
import '../domain/axis_mapping.dart';
import '../domain/hand_pipeline.dart';
import '../domain/stick_centre.dart';
import '../domain/tick_timer.dart';
import '../protocol/decoded_record.dart';
import '../protocol/gatt.dart';
import '../protocol/wmr_fragment.dart';

/// A reassembled frame with the phone-side receive time of its last fragment.
class ReceivedFrame {
  const ReceivedFrame(this.frame, this.receivedAtUs);

  final WmrFrame frame;
  final int receivedAtUs;
}

/// Per-hand stream counters. Gaps come from the ESP32 sequence numbers only.
class HandStats {
  const HandStats({
    this.frames = 0,
    this.incomplete = 0,
    this.lastSequence,
    this.gaps = 0,
    this.outOfOrder = 0,
  });

  final int frames;
  final int incomplete;
  final int? lastSequence;

  /// Frames missing between consecutive received sequence numbers.
  final int gaps;

  /// Received sequence numbers not greater than the previous one (duplicates,
  /// reordering, or an ESP32 reboot).
  final int outOfOrder;
}

class StreamStats {
  const StreamStats({required this.hands, this.errors = 0});

  final List<HandStats> hands;
  final int errors;
}

/// Which bridge characteristic the app listens to. Only one at a time.
enum StreamMode {
  /// FF11: raw fragmented frames (Capture needs this).
  raw,

  /// FF12: decoded 56-byte records (orientation needs this).
  decoded,
}

enum ModeFaultKind {
  /// ATT 0x80: the bridge says the other stream is still enabled.
  otherStreamActive,
  enableFailed,
  disableFailed,

  /// Negotiated ATT MTU below 59: the bridge sends nothing on FF12.
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
  });

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
}

class DecodedStats {
  const DecodedStats({
    required this.hands,
    this.wrongLength = 0,
    this.unknownVersion = 0,
    this.badHand = 0,
  });

  final List<DecodedHandStats> hands;
  final int wrongLength;
  final int unknownVersion;
  final int badHand;

  int get parseErrors => wrongLength + unknownVersion + badHand;
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

/// Subscribes to the bridge stream and turns it into frames (FF11) or fused
/// samples (FF12).
class ControllerService {
  ControllerService(
    this.transport,
    this.deviceId, {
    this._mode = StreamMode.raw,
    this._mapping = AxisMapping.defaultMapping,
    this._filterKind = FilterKind.madgwick,
    StickConfig stickConfig = const StickConfig(),
  }) : _stickConfig = stickConfig {
    for (final p in _pipelines) {
      p.mapping = _mapping;
      p.setFilter(_filterKind);
      p.stickConfig = stickConfig;
    }
  }

  final BleTransport transport;
  final String deviceId;

  final WmrReassembler _reassembler = WmrReassembler();
  final List<int?> _lastSeq = List.filled(wmrNumControllers, null);
  final List<int> _gaps = List.filled(wmrNumControllers, 0);
  final List<int> _outOfOrder = List.filled(wmrNumControllers, 0);
  final StreamController<ReceivedFrame> _frames = StreamController.broadcast();
  StreamSubscription<BleNotification>? _subscription;

  // Decoded (FF12) side.
  final List<HandPipeline> _pipelines = [
    for (var h = 0; h < wmrNumControllers; h++) HandPipeline(),
  ];
  final List<int?> _dLastSeq = List.filled(wmrNumControllers, null);
  final List<int> _dGaps = List.filled(wmrNumControllers, 0);
  final List<int> _dOutOfOrder = List.filled(wmrNumControllers, 0);
  final List<int> _dRecords = List.filled(wmrNumControllers, 0);
  final List<_RateMeter> _rates = [
    for (var h = 0; h < wmrNumControllers; h++) _RateMeter(),
  ];
  int _wrongLength = 0;
  int _unknownVersion = 0;
  int _badHand = 0;
  final StreamController<DecodedSample> _samples = StreamController.broadcast();

  StreamMode _mode;
  ModeFault? _fault;
  AxisMapping _mapping;
  FilterKind _filterKind;
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

  StreamMode get mode => _mode;
  ModeFault? get fault => _fault;
  ModeState get modeState => ModeState(_mode, fault: _fault);

  /// Emits whenever the requested mode or its fault changes.
  Stream<ModeState> get modeChanges => _modeChanges.stream;

  AxisMapping get mapping => _mapping;
  FilterKind get filterKind => _filterKind;

  HandPipeline pipeline(int hand) => _pipelines[hand];

  /// Connects and subscribes to the current [mode]. Call again after every
  /// reconnect: the bridge forgets the subscription on disconnect, and the
  /// wanted stream is enabled from scratch.
  Future<void> start() async {
    await transport.connect(deviceId);
    _started = true;
    await _subscribe();
  }

  /// Switches to [next]. The transport writes 0x0000 to the active
  /// characteristic's CCC before it enables the other one; a refusal
  /// (ATT 0x80) lands in [fault].
  Future<void> setMode(StreamMode next) async {
    if (next == _mode && _fault == null) return;
    _mode = next;
    _fault = null;
    _emitMode();
    if (_started) await _subscribe();
  }

  Future<void> _subscribe() async {
    await _subscription?.cancel();
    // Sequence numbers kept advancing while we were away or on the other
    // stream, so the first record of a new subscription is a new baseline,
    // not a gap. The same goes for tick timing.
    _lastSeq.fillRange(0, _lastSeq.length, null);
    _dLastSeq.fillRange(0, _dLastSeq.length, null);
    for (final p in _pipelines) {
      p.streamRestarted();
    }
    _fault = null;
    final decoded = _mode == StreamMode.decoded;
    _subscription = transport
        .subscribe(
          deviceId,
          wmrBridgeServiceUuid,
          decoded ? wmrBridgeDecodedCharUuid : wmrBridgeStreamCharUuid,
        )
        .listen(
          decoded ? _onDecoded : _onNotification,
          onError: _onStreamError,
        );
    if (decoded) await _checkMtu();
    _emitMode();
  }

  Future<void> _checkMtu() async {
    try {
      final mtu = (await transport.connectionInfo(deviceId)).mtu;
      if (mtu != null && mtu < wmrDecodedMinMtu && _fault == null) {
        _fault = ModeFault(
          ModeFaultKind.mtuTooSmall,
          'ATT MTU is $mtu; FF12 needs at least $wmrDecodedMinMtu, so the '
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

  void _onNotification(BleNotification n) {
    if (_reassembler.push(n.value) != ReassemblyResult.frameComplete) return;
    final frame = _reassembler.lastFrame!;
    final hand = frame.hand;
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
    _frames.add(ReceivedFrame(frame, n.receivedAtUs));
  }

  void _onDecoded(BleNotification n) {
    final parsed = parseDecodedRecord(n.value);
    final r = parsed.record;
    if (r == null) {
      switch (parsed.error!) {
        case DecodedParseError.wrongLength:
          _wrongLength++;
        case DecodedParseError.unknownVersion:
          _unknownVersion++;
        case DecodedParseError.badHand:
          _badHand++;
      }
      return;
    }
    final hand = r.hand;
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
    _rates[hand].add(n.receivedAtUs);
    final sample = _pipelines[hand].add(r, n.receivedAtUs);
    _lastStick[hand] = sample.stick;
    _samples.add(sample);
  }

  /// Applies [m] to both hands from the next sample on.
  void setMapping(AxisMapping m) {
    _mapping = m;
    for (final p in _pipelines) {
      p.mapping = m;
    }
  }

  /// Applies [c] to both hands from the next sample on.
  void setStickConfig(StickConfig c) {
    _stickConfig = c;
    for (final p in _pipelines) {
      p.stickConfig = c;
    }
  }

  StickConfig get stickConfig => _stickConfig;

  /// Takes the current stick position of [hand] as its rest centre.
  void recentreStick(int hand) => _pipelines[hand].recentreStick();

  void setFilterKind(FilterKind k) {
    _filterKind = k;
    for (final p in _pipelines) {
      p.setFilter(k);
    }
  }

  /// Re-estimates the gyro bias of [hand] from the next stationary second.
  void recalibrate(int hand) => _pipelines[hand].recalibrate();

  void resetYaw(int hand) => _pipelines[hand].resetYaw();

  StreamStats get stats => StreamStats(
    hands: [
      for (var h = 0; h < wmrNumControllers; h++)
        HandStats(
          frames: _reassembler.framesComplete[h],
          incomplete: _reassembler.framesIncomplete[h],
          lastSequence: _lastSeq[h],
          gaps: _gaps[h],
          outOfOrder: _outOfOrder[h],
        ),
    ],
    errors: _reassembler.errors,
  );

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
          ),
      ],
      wrongLength: _wrongLength,
      unknownVersion: _unknownVersion,
      badHand: _badHand,
    );
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _frames.close();
    await _samples.close();
    await _modeChanges.close();
  }
}
