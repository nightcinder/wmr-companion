/// Link timing measured on the phone: inter-arrival, sequence gaps, loss from
/// device ticks and one-way delay variation, plus the CSV/JSON export.
///
/// Pure Dart. A round trip is measured only when the caller feeds echo samples
/// ([LatencyRecorder.addEcho], from the bridge's FF15 echo); otherwise the
/// report says it was not measured. From the streams alone:
///
/// - Inter-arrival of distinct phone arrival times per hand. Records that share
///   one notification (batching) count once.
/// - Sequence gaps and out-of-order numbers (loss after the ESP32 numbered a
///   report).
/// - Decoded streams only: reports missing by the controller's tick deltas
///   (the firmware definition, see [TickTimer]) and the one-way delay
///   variation from the record's ESP32 receive time. The ESP32 and phone
///   clocks have unrelated origins and drift apart, so only differences of
///   `arrival - rx_time` inside a short window are used, never an absolute
///   value.
library;

import 'dart:convert';

import '../domain/tick_timer.dart';
import '../protocol/wmr_fragment.dart';
import 'echo_client.dart';

const String latencyFormatName = 'wmr-latency';

/// Version 2: `round_trip` is an object (`measured` plus the figures) instead
/// of a string.
const int latencyFormatVersion = 2;

/// Inter-arrival above this counts as a stall.
const int latencyStallUs = 50000;

/// Window for the relative one-way delay: short, so clock drift between the
/// ESP32 and the phone (tens of ppm) stays well under a millisecond.
const int latencyDelayWindowUs = 10000000;

/// Percentiles of a set of microsecond values (nearest rank).
class UsPercentiles {
  const UsPercentiles({
    this.count = 0,
    this.min = 0,
    this.p50 = 0,
    this.p90 = 0,
    this.p95 = 0,
    this.p99 = 0,
    this.max = 0,
  });

  factory UsPercentiles.of(List<int> values) {
    if (values.isEmpty) return const UsPercentiles();
    final sorted = List<int>.of(values)..sort();
    int at(double q) => sorted[(q * (sorted.length - 1)).round()];
    return UsPercentiles(
      count: sorted.length,
      min: sorted.first,
      p50: at(0.5),
      p90: at(0.9),
      p95: at(0.95),
      p99: at(0.99),
      max: sorted.last,
    );
  }

  final int count;
  final int min;
  final int p50;
  final int p90;
  final int p95;
  final int p99;
  final int max;

  Map<String, Object> toJson() => {
    'count': count,
    'min_us': min,
    'p50_us': p50,
    'p90_us': p90,
    'p95_us': p95,
    'p99_us': p99,
    'max_us': max,
  };
}

/// Link parameters at the start and end of a run. Null where the platform
/// does not say.
class LatencyLink {
  const LatencyLink({
    this.mtu,
    this.rssiStart,
    this.rssiEnd,
    this.connectionIntervalUs,
    this.phy,
    this.priorityRequested,
  });

  final int? mtu;
  final int? rssiStart;
  final int? rssiEnd;
  final int? connectionIntervalUs;
  final String? phy;

  /// True when high connection priority was requested successfully; null
  /// where the platform has no such call.
  final bool? priorityRequested;

  LatencyLink withEnd({int? rssiEnd}) => LatencyLink(
    mtu: mtu,
    rssiStart: rssiStart,
    rssiEnd: rssiEnd,
    connectionIntervalUs: connectionIntervalUs,
    phy: phy,
    priorityRequested: priorityRequested,
  );

  Map<String, Object?> toJson() => {
    'mtu': mtu,
    'rssi_start_dbm': rssiStart,
    'rssi_end_dbm': rssiEnd,
    'connection_interval_us': connectionIntervalUs,
    'phy': phy,
    'high_priority_requested': priorityRequested,
  };
}

/// One hand's figures for a run.
class LatencyHandSummary {
  const LatencyHandSummary({
    required this.hand,
    this.records = 0,
    this.arrivals = 0,
    this.spanUs = 0,
    this.interArrival = const UsPercentiles(),
    this.stalls = 0,
    this.sequenceGaps = 0,
    this.outOfOrder = 0,
    this.missingFromTicks,
    this.periodUs,
    this.delay,
    this.delayVariation,
  });

  final int hand;

  /// Frames (raw) or records (decoded) received.
  final int records;

  /// Distinct arrival times: notifications that carried at least one complete
  /// record of this hand.
  final int arrivals;

  /// First to last arrival.
  final int spanUs;
  final UsPercentiles interArrival;

  /// Inter-arrival values above [latencyStallUs].
  final int stalls;
  final int sequenceGaps;
  final int outOfOrder;

  /// Decoded only: reports missing by the controller's tick deltas.
  final int? missingFromTicks;

  /// Decoded only: nominal report period from the tick deltas.
  final int? periodUs;

  /// Decoded only: `arrival - rx_time` above the smallest value of its 10 s
  /// window. Queueing and connection-event wait between the ESP32 receiving a
  /// report and the phone seeing it, without the fixed part.
  final UsPercentiles? delay;

  /// Decoded only: |change of `arrival - rx_time`| between consecutive
  /// records of this hand.
  final UsPercentiles? delayVariation;

  double get ratePerSecond => spanUs <= 0 ? 0 : records * 1e6 / spanUs;

  /// Sequence gaps over numbered reports (received plus gaps).
  double get sequenceLoss {
    final total = records + sequenceGaps;
    return total == 0 ? 0 : sequenceGaps / total;
  }

  /// Tick-based missing over expected reports (received plus missing).
  double? get tickLoss {
    final m = missingFromTicks;
    if (m == null) return null;
    final total = records + m;
    return total == 0 ? 0 : m / total;
  }

  Map<String, Object?> toJson() => {
    'hand': handName(hand),
    'records': records,
    'arrivals': arrivals,
    'span_us': spanUs,
    'rate_per_s': _round(ratePerSecond, 2),
    'inter_arrival': interArrival.toJson(),
    'stalls_over_${latencyStallUs}us': stalls,
    'sequence_gaps': sequenceGaps,
    'sequence_loss': _round(sequenceLoss, 4),
    'out_of_order': outOfOrder,
    'missing_from_ticks': missingFromTicks,
    'tick_loss': tickLoss == null ? null : _round(tickLoss!, 4),
    'period_us': periodUs,
    'delay_above_window_min': delay?.toJson(),
    'delay_variation': delayVariation?.toJson(),
  };

  static String handName(int hand) => switch (hand) {
    wmrHandLeft => 'LEFT',
    wmrHandRight => 'RIGHT',
    _ => 'HAND$hand',
  };
}

/// Round-trip figures of a run, from the FF15 echo.
class EchoSummary {
  const EchoSummary({
    this.answered = 0,
    this.timeouts = 0,
    this.failedWrites = 0,
    this.rtt = const UsPercentiles(),
    this.endToEnd = const UsPercentiles(),
    this.turnaround = const UsPercentiles(),
    this.maxQueueDepth = 0,
    this.counters = const {},
  });

  final int answered;
  final int timeouts;
  final int failedWrites;

  /// `(t4 - t1) - turnaround`: see [EchoSample.rttUs].
  final UsPercentiles rtt;

  /// `t4 - t1`: write call to notification, what the app sees.
  final UsPercentiles endToEnd;

  /// Time the answer waited on the ESP32.
  final UsPercentiles turnaround;

  /// Largest stream backlog the answers skipped.
  final int maxQueueDepth;

  /// Client counters (late answers, bad answers, pings skipped), by name.
  final Map<String, int> counters;

  int get sent => answered + timeouts + failedWrites;

  Map<String, Object?> toJson() => {
    'measured': true,
    'source': 'FF15 echo',
    'sent': sent,
    'answered': answered,
    'timeouts': timeouts,
    'failed_writes': failedWrites,
    'rtt': rtt.toJson(),
    'end_to_end': endToEnd.toJson(),
    'turnaround': turnaround.toJson(),
    'max_queue_depth': maxQueueDepth,
    'counters': counters,
  };
}

/// A finished (or in-progress) run.
class LatencyReport {
  const LatencyReport({
    required this.started,
    required this.stream,
    required this.durationUs,
    required this.hands,
    this.link = const LatencyLink(),
    this.counters = const {},
    this.rowsDropped = 0,
    this.modeChanged = false,
    this.echo,
    this.echoIntervalUs,
  });

  final DateTime started;

  /// The stream mode the run listened to, as the service names it
  /// (`raw`, `decoded`, `batched`, or `none` for an FF15-only run).
  final String stream;
  final int durationUs;
  final List<LatencyHandSummary> hands;
  final LatencyLink link;

  /// Service counters that grew during the run (incomplete frames, parse
  /// errors, ...), by name.
  final Map<String, int> counters;

  /// Rows not kept for the CSV because the run hit its row limit. The summary
  /// still counts them.
  final int rowsDropped;

  /// The stream mode changed while the run was going: its figures mix two
  /// streams.
  final bool modeChanged;

  /// Null when no echo was used: the round trip was not measured.
  final EchoSummary? echo;

  /// Time between echo pings, when a round trip was measured.
  final int? echoIntervalUs;

  Map<String, Object?> toJson() => {
    'format': latencyFormatName,
    'version': latencyFormatVersion,
    'source': 'wmr_companion app (phone)',
    'started': started.toIso8601String(),
    'stream': stream,
    'duration_us': durationUs,
    'round_trip': echo == null
        ? {
            'measured': false,
            'reason': 'echo not used (needs the FF15 echo, WMR_Bridge #13)',
          }
        : {
            ...echo!.toJson(),
            if (echoIntervalUs != null) 'ping_interval_us': echoIntervalUs,
          },
    'link': link.toJson(),
    'counters': counters,
    'rows_dropped': rowsDropped,
    'mode_changed': modeChanged,
    'hands': [for (final h in hands) h.toJson()],
  };

  String toJsonString() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';
}

/// One received frame or record, as written to the CSV.
class LatencyRow {
  const LatencyRow({
    required this.hand,
    required this.sequence,
    required this.arrivalUs,
    this.interArrivalUs,
    this.sequenceDelta,
    this.deviceTicks,
    this.deviceDtUs,
    this.espRxUs,
  });

  final int hand;
  final int sequence;

  /// Phone monotonic time since the run started.
  final int arrivalUs;

  /// Since the previous distinct arrival of this hand; 0 when the record
  /// shares a notification with the previous one; empty for the first.
  final int? interArrivalUs;
  final int? sequenceDelta;
  final int? deviceTicks;

  /// Controller time since the previous record of this hand (decoded only).
  final int? deviceDtUs;

  /// ESP32 receive time, raw (decoded only). Another clock: do not subtract
  /// it from [arrivalUs].
  final int? espRxUs;

  static const String csvHeader =
      'hand,sequence,arrival_us,inter_arrival_us,seq_delta,device_ticks,'
      'device_dt_us,esp_rx_us';

  String toCsv() => [
    LatencyHandSummary.handName(hand),
    sequence,
    arrivalUs,
    interArrivalUs ?? '',
    sequenceDelta ?? '',
    deviceTicks ?? '',
    deviceDtUs ?? '',
    espRxUs ?? '',
  ].join(',');
}

/// One answered echo, as written to the echo CSV. Phone times are relative to
/// the start of the run; ESP32 times are raw.
class EchoRow {
  const EchoRow(this.sample, this.originUs);

  final EchoSample sample;
  final int originUs;

  static const String csvHeader =
      'ping_id,t1_us,t1_done_us,t4_us,end_to_end_us,esp_rx_us,turnaround_us,'
      'rtt_us,queue_depth,clock_offset_us';

  String toCsv() {
    final s = sample;
    return [
      s.pingId,
      s.t1Us - originUs,
      s.t1DoneUs - originUs,
      s.t4Us - originUs,
      s.endToEndUs,
      s.answer.rxTimeUs,
      s.answer.turnaroundUs,
      s.rttUs,
      s.answer.queueDepth,
      s.offsetUs,
    ].join(',');
  }
}

class _HandState {
  int records = 0;
  int arrivals = 0;
  int? firstUs;
  int? lastUs;
  int? lastSeq;
  int gaps = 0;
  int outOfOrder = 0;
  int stalls = 0;
  final List<int> interArrival = [];

  // Decoded only.
  TickTimer? timer;
  int? lastOffset;
  final List<int> variation = [];

  // Offsets (`arrival - rx_time`) of the current delay window.
  int? windowStartUs;
  final List<int> windowOffsets = [];
  final List<int> delay = [];

  void closeWindow() {
    if (windowOffsets.isEmpty) return;
    final min = windowOffsets.reduce((a, b) => a < b ? a : b);
    for (final o in windowOffsets) {
      delay.add(o - min);
    }
    windowOffsets.clear();
  }
}

/// Collects one run. Feed it with [addFrame] (raw stream) or [addRecord]
/// (decoded stream; batched records with the arrival time of their
/// notification). Cheap per call: appends only; percentiles are computed in
/// [report].
class LatencyRecorder {
  LatencyRecorder({
    required this.started,
    required this.originUs,
    required this.stream,
    this.maxRows = 250000,
  });

  final DateTime started;

  /// Phone monotonic time at the start of the run.
  final int originUs;
  final String stream;

  /// Rows kept for the CSV. A 2-minute run of both hands at 200 Hz is about
  /// 48 000.
  final int maxRows;

  final List<_HandState> _hands = [
    for (var h = 0; h < wmrNumControllers; h++) _HandState(),
  ];
  final List<LatencyRow> _rows = [];
  final List<EchoRow> _echoRows = [];
  int _echoTimeouts = 0;
  int _echoFailed = 0;
  bool _echoUsed = false;
  int _rowsDropped = 0;
  bool _modeChanged = false;

  List<LatencyRow> get rows => List.unmodifiable(_rows);
  List<EchoRow> get echoRows => List.unmodifiable(_echoRows);

  /// True once any echo result was fed in, so the report has a round-trip
  /// section (and the export an echo file) even when every ping timed out.
  bool get echoUsed => _echoUsed;

  /// Declares that echo pings are part of this run.
  void useEcho() => _echoUsed = true;

  /// An answered ping.
  void addEcho(EchoSample sample) {
    _echoUsed = true;
    _echoRows.add(EchoRow(sample, originUs));
  }

  /// A ping that got no answer within the timeout.
  void addEchoTimeout() {
    _echoUsed = true;
    _echoTimeouts++;
  }

  /// A ping whose write failed.
  void addEchoFailure() {
    _echoUsed = true;
    _echoFailed++;
  }

  int get rowsDropped => _rowsDropped;

  /// Call when the service switched streams during the run.
  void markModeChanged() => _modeChanged = true;

  /// A reassembled raw frame.
  void addFrame(int hand, int sequence, int arrivalUs) =>
      _add(hand, sequence, arrivalUs);

  /// A decoded record: its sequence, the controller tick counter and the
  /// ESP32 receive time.
  void addRecord(
    int hand,
    int sequence,
    int arrivalUs, {
    required int deviceTicks,
    required int espRxUs,
  }) => _add(
    hand,
    sequence,
    arrivalUs,
    deviceTicks: deviceTicks,
    espRxUs: espRxUs,
  );

  void _add(
    int hand,
    int sequence,
    int arrivalUs, {
    int? deviceTicks,
    int? espRxUs,
  }) {
    if (hand < 0 || hand >= wmrNumControllers) return;
    final s = _hands[hand];
    s.records++;

    int? inter;
    final last = s.lastUs;
    if (last == null) {
      s.arrivals++;
      s.firstUs = arrivalUs;
    } else if (arrivalUs != last) {
      inter = arrivalUs - last;
      s.arrivals++;
      s.interArrival.add(inter);
      if (inter > latencyStallUs) s.stalls++;
    } else {
      inter = 0;
    }
    s.lastUs = arrivalUs;

    int? seqDelta;
    final lastSeq = s.lastSeq;
    if (lastSeq != null) {
      seqDelta = sequenceDelta(lastSeq, sequence);
      if (seqDelta > 1) {
        s.gaps += seqDelta - 1;
      } else if (seqDelta <= 0) {
        s.outOfOrder++;
      }
    }
    s.lastSeq = sequence;

    int? deviceDtUs;
    if (deviceTicks != null && espRxUs != null) {
      final step = (s.timer ??= TickTimer()).advance(deviceTicks, espRxUs);
      if (step.kind == TickStepKind.step) deviceDtUs = step.dtTicks ~/ 10;
      _addDelay(s, arrivalUs, espRxUs, step.kind);
    }

    if (_rows.length < maxRows) {
      _rows.add(
        LatencyRow(
          hand: hand,
          sequence: sequence,
          arrivalUs: arrivalUs - originUs,
          interArrivalUs: inter,
          sequenceDelta: seqDelta,
          deviceTicks: deviceTicks,
          deviceDtUs: deviceDtUs,
          espRxUs: espRxUs,
        ),
      );
    } else {
      _rowsDropped++;
    }
  }

  void _addDelay(_HandState s, int arrivalUs, int espRxUs, TickStepKind kind) {
    // Never an absolute latency: the two clocks have unrelated origins.
    final offset = arrivalUs - espRxUs;
    if (kind == TickStepKind.discontinuity) {
      // ESP32 reboot or controller timer restart: new baseline for both.
      s.closeWindow();
      s.windowStartUs = null;
      s.lastOffset = null;
    }
    final prev = s.lastOffset;
    if (prev != null) s.variation.add((offset - prev).abs());
    s.lastOffset = offset;

    final start = s.windowStartUs;
    if (start == null || arrivalUs - start >= latencyDelayWindowUs) {
      s.closeWindow();
      s.windowStartUs = arrivalUs;
    }
    s.windowOffsets.add(offset);
  }

  /// Figures so far. [link] and [counters] come from the caller.
  LatencyReport report({
    required int nowUs,
    LatencyLink link = const LatencyLink(),
    Map<String, int> counters = const {},
    Map<String, int> echoCounters = const {},
    int? echoIntervalUs,
  }) {
    return LatencyReport(
      echo: _echoUsed ? _echoSummary(echoCounters) : null,
      echoIntervalUs: _echoUsed ? echoIntervalUs : null,
      started: started,
      stream: stream,
      durationUs: nowUs - originUs,
      link: link,
      counters: counters,
      rowsDropped: _rowsDropped,
      modeChanged: _modeChanged,
      hands: [
        for (var h = 0; h < wmrNumControllers; h++) _summary(h, _hands[h]),
      ],
    );
  }

  EchoSummary _echoSummary(Map<String, int> counters) {
    final samples = [for (final r in _echoRows) r.sample];
    var maxQueue = 0;
    for (final s in samples) {
      if (s.answer.queueDepth > maxQueue) maxQueue = s.answer.queueDepth;
    }
    return EchoSummary(
      answered: samples.length,
      timeouts: _echoTimeouts,
      failedWrites: _echoFailed,
      rtt: UsPercentiles.of([for (final s in samples) s.rttUs]),
      endToEnd: UsPercentiles.of([for (final s in samples) s.endToEndUs]),
      turnaround: UsPercentiles.of([
        for (final s in samples) s.answer.turnaroundUs,
      ]),
      maxQueueDepth: maxQueue,
      counters: counters,
    );
  }

  LatencyHandSummary _summary(int hand, _HandState s) {
    final timer = s.timer;
    List<int>? delay;
    if (timer != null) {
      // The open window counts too, without closing it.
      final open = s.windowOffsets;
      final min = open.isEmpty ? 0 : open.reduce((a, b) => a < b ? a : b);
      delay = [...s.delay, for (final o in open) o - min];
    }
    final period = timer?.periodTicks;
    return LatencyHandSummary(
      hand: hand,
      records: s.records,
      arrivals: s.arrivals,
      spanUs: (s.lastUs ?? 0) - (s.firstUs ?? 0),
      interArrival: UsPercentiles.of(s.interArrival),
      stalls: s.stalls,
      sequenceGaps: s.gaps,
      outOfOrder: s.outOfOrder,
      missingFromTicks: timer?.missing,
      periodUs: period == null ? null : period ~/ 10,
      delay: delay == null ? null : UsPercentiles.of(delay),
      delayVariation: timer == null ? null : UsPercentiles.of(s.variation),
    );
  }

  /// All kept rows with a header line.
  String toCsv() {
    final b = StringBuffer(LatencyRow.csvHeader)..write('\n');
    for (final r in _rows) {
      b
        ..write(r.toCsv())
        ..write('\n');
    }
    return b.toString();
  }

  /// The answered pings with a header line.
  String toEchoCsv() {
    final b = StringBuffer(EchoRow.csvHeader)..write('\n');
    for (final r in _echoRows) {
      b
        ..write(r.toCsv())
        ..write('\n');
    }
    return b.toString();
  }
}

double _round(double v, int digits) {
  final s = v.toStringAsFixed(digits);
  return double.parse(s);
}
