import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:wmr_tracking/wmr_tracking.dart';

/// Format tag for a gate 7 replay fixture.
const String gate7FixtureFormat = 'wmr-gate7-clock-fixture';

/// Newest fixture version this harness reads.
const int gate7FixtureVersion = 1;

/// Gate 7 passes when the aligner offset standard deviation is below this.
const int gate7MaxOffsetStdNs = 5000000; // 5 ms

/// Gate 7 passes when fewer than 1% of frames are older than this window.
const int gate7FrameWindowNs = 100000000; // 100 ms

/// Longest controller-capture gap a minute-long clock run may contain.
const int gate7MaxControllerGapNs = 100000000; // 100 ms

/// Gate 7 passes while no more than this fraction of frames is stale.
const double gate7MaxStaleFraction = 0.01;

/// A fixture or capture that the harness cannot read.
class Gate7Exception implements Exception {
  const Gate7Exception(this.message);

  final String message;

  @override
  String toString() => 'Gate7Exception: $message';
}

/// One synthetic tracking/head timestamp and the host time it arrived at.
class HeadTraceSample {
  const HeadTraceSample({required this.sourceTimeNs, required this.hostTimeNs});

  final int sourceTimeNs;
  final int hostTimeNs;
}

/// Parameters for the deterministic synthetic head-timestamp trace.
class HeadTraceSpec {
  const HeadTraceSpec({
    required this.startSourceNs,
    required this.startHostNs,
    required this.rateHz,
    required this.durationS,
    required this.jitterNs,
    required this.seed,
    required this.driftNsPerS,
    this.hostStepNs = 0,
    this.hostStepAfterS = 0,
  });

  final int startSourceNs;
  final int startHostNs;
  final double rateHz;
  final double durationS;
  final int jitterNs;
  final int seed;

  /// Host-minus-source offset growth per second of source time.
  final int driftNsPerS;

  /// One-off host-time step applied after [hostStepAfterS] seconds.
  final int hostStepNs;

  /// Source time, in seconds, after which [hostStepNs] applies.
  final double hostStepAfterS;

  /// Builds a repeatable trace. Jitter is uniform in +/- [jitterNs].
  List<HeadTraceSample> generate() {
    if (rateHz <= 0 || durationS <= 0) {
      throw const Gate7Exception(
        'head.rate_hz and head.duration_s must be > 0',
      );
    }
    if (jitterNs < 0) {
      throw const Gate7Exception('head.jitter_ns must be >= 0');
    }
    final count = (rateHz * durationS).round();
    if (count < 2) {
      throw const Gate7Exception('head trace needs at least two samples');
    }
    final stepNs = 1e9 / rateHz;
    final random = math.Random(seed);
    final samples = <HeadTraceSample>[];
    for (var i = 0; i < count; i++) {
      final elapsedNs = (i * stepNs).round();
      final jitter = jitterNs == 0
          ? 0
          : random.nextInt(jitterNs * 2 + 1) - jitterNs;
      final drift = (driftNsPerS * elapsedNs / 1e9).round();
      final step = elapsedNs >= hostStepAfterS * 1e9 ? hostStepNs : 0;
      samples.add(
        HeadTraceSample(
          sourceTimeNs: startSourceNs + elapsedNs,
          hostTimeNs: startHostNs + elapsedNs + jitter + drift + step,
        ),
      );
    }
    return samples;
  }
}

/// A fixture: a recorded controller capture plus a synthetic head trace.
class Gate7Fixture {
  const Gate7Fixture({
    required this.name,
    required this.capturePath,
    required this.captureName,
    required this.hand,
    required this.head,
  });

  final String name;
  final String capturePath;
  final String captureName;
  final String hand;
  final HeadTraceSpec head;

  static Gate7Fixture load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw Gate7Exception('fixture not found: $path');
    }
    final Object? document;
    try {
      document = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw Gate7Exception('fixture is not JSON: ${error.message}');
    }
    if (document is! Map<String, Object?>) {
      throw const Gate7Exception('fixture must be a JSON object');
    }
    if (document['format'] != gate7FixtureFormat) {
      throw Gate7Exception('fixture format must be "$gate7FixtureFormat"');
    }
    if (document['version'] != gate7FixtureVersion) {
      throw Gate7Exception(
        'unsupported fixture version ${document['version']}',
      );
    }
    final capture = document['capture'];
    if (capture is! String || capture.isEmpty) {
      throw const Gate7Exception('fixture.capture must be a path');
    }
    final hand = document['hand'] ?? 'right';
    if (hand != 'left' && hand != 'right') {
      throw const Gate7Exception('fixture.hand must be "left" or "right"');
    }
    final head = document['head'];
    if (head is! Map<String, Object?>) {
      throw const Gate7Exception('fixture.head must be an object');
    }
    final resolvedCapture = File(capture).isAbsolute
        ? capture
        : '${file.absolute.parent.path}${Platform.pathSeparator}$capture';
    return Gate7Fixture(
      name: document['name'] is String ? document['name']! as String : path,
      capturePath: resolvedCapture,
      captureName: capture,
      hand: hand as String,
      head: HeadTraceSpec(
        startSourceNs: _int(head, 'start_source_ns'),
        startHostNs: _int(head, 'start_host_ns'),
        rateHz: _double(head, 'rate_hz'),
        durationS: _double(head, 'duration_s'),
        jitterNs: _int(head, 'jitter_ns', fallback: 0),
        seed: _int(head, 'seed', fallback: 0),
        driftNsPerS: _int(head, 'drift_ns_per_s', fallback: 0),
        hostStepNs: _int(head, 'host_step_ns', fallback: 0),
        hostStepAfterS: _optionalDouble(head, 'host_step_after_s'),
      ),
    );
  }

  static int _int(Map<String, Object?> map, String key, {int? fallback}) {
    final value = map[key] ?? fallback;
    if (value is! int) {
      throw Gate7Exception('$key must be an integer');
    }
    return value;
  }

  static double _double(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! num) {
      throw Gate7Exception('$key must be a number');
    }
    return value.toDouble();
  }

  static double _optionalDouble(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value == null) return 0;
    if (value is! num) {
      throw Gate7Exception('$key must be a number');
    }
    return value.toDouble();
  }
}

/// Controller arrival timestamps from a WMR capture, in host nanoseconds.
class ControllerCapture {
  const ControllerCapture({required this.receivedNs, required this.path});

  final List<int> receivedNs;
  final String path;

  int get maxGapNs {
    var maximum = 0;
    for (var i = 1; i < receivedNs.length; i++) {
      final gap = receivedNs[i] - receivedNs[i - 1];
      if (gap > maximum) maximum = gap;
    }
    return maximum;
  }

  static ControllerCapture read(String path, {required String hand}) {
    final file = File(path);
    if (!file.existsSync()) {
      throw Gate7Exception('capture not found: $path');
    }
    final handField = hand == 'right' ? 1 : 0;
    final received = <int>[];
    var lineNumber = 0;
    for (final rawLine in file.readAsLinesSync()) {
      lineNumber++;
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('@')) {
        continue;
      }
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length != 5 || fields[0] != 'F') {
        throw Gate7Exception('$path:$lineNumber: not an F line');
      }
      final seconds = double.tryParse(fields[1]);
      final lineHand = int.tryParse(fields[2]);
      if (seconds == null || lineHand == null) {
        throw Gate7Exception('$path:$lineNumber: bad time or hand');
      }
      if (lineHand != handField) continue;
      final hex = fields[4];
      if (hex.length != 92 || !hex.toLowerCase().startsWith('a101')) {
        throw Gate7Exception('$path:$lineNumber: not a 46-byte A1 01 frame');
      }
      received.add((seconds * 1e9).round());
    }
    if (received.length < 2) {
      throw Gate7Exception('$path: fewer than two $hand frames');
    }
    received.sort();
    return ControllerCapture(receivedNs: received, path: path);
  }
}

/// Result of replaying one fixture through [SourceClockAligner].
class Gate7Result {
  const Gate7Result({
    required this.fixture,
    required this.hand,
    required this.capture,
    required this.stats,
    required this.reasons,
  });

  final String fixture;
  final String hand;
  final String capture;
  final Gate7Stats stats;
  final List<String> reasons;

  bool get passed => reasons.isEmpty;

  Map<String, Object?> toJson() => {
    'fixture': fixture,
    'hand': hand,
    'capture': capture,
    'verdict': passed ? 'pass' : 'fail',
    'reasons': reasons,
    ...stats.toJson(),
    'thresholds': {
      'offset_std_ms': gate7MaxOffsetStdNs / 1e6,
      'frame_window_ms': gate7FrameWindowNs / 1e6,
      'controller_gap_ms': gate7MaxControllerGapNs / 1e6,
      'max_stale_fraction': gate7MaxStaleFraction,
    },
  };

  /// Reads [fixturePath] and replays its capture plus head trace.
  static Gate7Result run(String fixturePath) {
    final fixture = Gate7Fixture.load(fixturePath);
    final capture = ControllerCapture.read(
      fixture.capturePath,
      hand: fixture.hand,
    );
    return replay(fixture, capture);
  }

  /// Feeds [fixture]'s synthetic trace through the aligner against [capture].
  static Gate7Result replay(Gate7Fixture fixture, ControllerCapture capture) {
    final trace = fixture.head.generate();
    final aligner = SourceClockAligner();
    final resetNs = aligner.resetThreshold.inMicroseconds * 1000;
    final offsets = <int>[];
    final alignedTimes = <int>[];
    int? previousSource;
    var rebases = 0;
    var rejected = 0;
    for (final sample in trace) {
      if (previousSource != null &&
          sample.sourceTimeNs < previousSource - resetNs) {
        rebases++;
      }
      previousSource = sample.sourceTimeNs;
      final rawOffset = sample.hostTimeNs - sample.sourceTimeNs;
      final before = aligner.offsetNs;
      if (before != null &&
          (rawOffset - before).abs() >
              aligner.maxCorrection.inMicroseconds * 1000) {
        rejected++;
      }
      alignedTimes.add(
        aligner.align(
          sourceTimeNs: sample.sourceTimeNs,
          hostTimeNs: sample.hostTimeNs,
        ),
      );
      offsets.add(aligner.offsetNs!);
    }

    // Mirror SixDofFuser.update: at each controller sample, only frames that
    // have actually arrived are in the buffer. Use the newest aligned frame up
    // to 5 ms in the future and age anything past 100 ms.
    final toleranceNs =
        const SixDofFusionConfig().lateTolerance.inMicroseconds * 1000;
    final arrived = <int>[];
    var headIndex = 0;
    var evaluated = 0;
    var staleFrames = 0;
    var maxAge = 0;
    for (final controllerNs in capture.receivedNs) {
      while (headIndex < trace.length &&
          trace[headIndex].hostTimeNs <= controllerNs) {
        final aligned = alignedTimes[headIndex];
        var at = arrived.length;
        while (at > 0 && arrived[at - 1] > aligned) {
          at--;
        }
        arrived.insert(at, aligned);
        headIndex++;
      }
      if (arrived.isEmpty) continue;
      final limit = controllerNs + toleranceNs;
      var low = 0;
      var high = arrived.length;
      while (low < high) {
        final mid = (low + high) >> 1;
        if (arrived[mid] <= limit) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      if (low == 0) continue;
      evaluated++;
      final age = (controllerNs - arrived[low - 1]).abs();
      if (age > maxAge) maxAge = age;
      if (age > gate7FrameWindowNs) staleFrames++;
    }

    final mean = offsets.reduce((a, b) => a + b) / offsets.length;
    var squared = 0.0;
    var minimum = offsets.first;
    var maximum = offsets.first;
    for (final offset in offsets) {
      final delta = (offset - mean).toDouble();
      squared += delta * delta;
      if (offset < minimum) minimum = offset;
      if (offset > maximum) maximum = offset;
    }
    final std = math.sqrt(squared / offsets.length);
    final staleFraction = evaluated == 0 ? 1.0 : staleFrames / evaluated;
    final reasons = <String>[
      if (std > gate7MaxOffsetStdNs) 'offset_drift',
      if (capture.maxGapNs > gate7MaxControllerGapNs) 'controller_gap',
      if (staleFraction > gate7MaxStaleFraction) 'frame_out_of_window',
    ];
    return Gate7Result(
      fixture: fixture.name,
      hand: fixture.hand,
      capture: fixture.captureName,
      reasons: reasons,
      stats: Gate7Stats(
        capture: capture,
        samples: trace.length,
        evaluatedFrames: evaluated,
        offsetMeanNs: mean,
        offsetStdNs: std,
        offsetMinNs: minimum,
        offsetMaxNs: maximum,
        maxFrameAgeNs: maxAge,
        staleFrames: staleFrames,
        staleFraction: staleFraction,
        rebases: rebases,
        rejectedCorrections: rejected,
        durationNs: trace.last.sourceTimeNs - trace.first.sourceTimeNs,
      ),
    );
  }
}

/// Numeric gate 7 statistics, in nanoseconds.
class Gate7Stats {
  const Gate7Stats({
    required this.capture,
    required this.samples,
    required this.evaluatedFrames,
    required this.offsetMeanNs,
    required this.offsetStdNs,
    required this.offsetMinNs,
    required this.offsetMaxNs,
    required this.maxFrameAgeNs,
    required this.staleFrames,
    required this.staleFraction,
    required this.rebases,
    required this.rejectedCorrections,
    required this.durationNs,
  });

  final ControllerCapture capture;
  final int samples;
  final int evaluatedFrames;
  final double offsetMeanNs;
  final double offsetStdNs;
  final int offsetMinNs;
  final int offsetMaxNs;
  final int maxFrameAgeNs;
  final int staleFrames;
  final double staleFraction;
  final int rebases;
  final int rejectedCorrections;
  final int durationNs;

  Map<String, Object?> toJson() => {
    'samples': samples,
    'evaluated_frames': evaluatedFrames,
    'controller_samples': capture.receivedNs.length,
    'duration_ms': _ms(durationNs),
    'offset_ms': {
      'mean': _ms(offsetMeanNs),
      'std': _ms(offsetStdNs),
      'min': _ms(offsetMinNs),
      'max': _ms(offsetMaxNs),
    },
    'max_frame_age_ms': _ms(maxFrameAgeNs),
    'frames_over_window': staleFrames,
    'frames_over_window_pct': _round(staleFraction * 100),
    'controller_max_gap_ms': _ms(capture.maxGapNs),
    'rebases': rebases,
    'rejected_corrections': rejectedCorrections,
  };

  static double _ms(num ns) => _round(ns / 1e6);

  static double _round(num value) => double.parse(value.toStringAsFixed(3));
}
