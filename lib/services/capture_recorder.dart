/// Raw capture recorder. Writes the text format of WMR_Bridge
/// `tools/capture_ble.py` (see docs/CAPTURE.md) so `tools/analyze_capture.py`
/// reads phone captures unchanged. Pure Dart: output goes through
/// [CaptureSink].
library;

import 'dart:async';

import '../protocol/wmr_fragment.dart';
import 'controller_service.dart';

/// Where capture text goes. [add] must be cheap and must not block: it runs
/// once per frame on the path that receives notifications. There is no
/// flush: a pending `IOSink.flush` makes later writes throw, and [close]
/// drains the buffer.
abstract class CaptureSink {
  void add(String text);
  Future<void> close();
}

/// Collects text in memory. For tests.
class MemoryCaptureSink implements CaptureSink {
  final StringBuffer _buffer = StringBuffer();
  bool closed = false;

  String get text => _buffer.toString();

  @override
  void add(String text) => _buffer.write(text);

  @override
  Future<void> close() async => closed = true;
}

/// One phase of the guided procedure. The analysis script keys on [name].
class CapturePhase {
  const CapturePhase(this.name, this.instructions, {this.minSeconds = 0});

  final String name;
  final String instructions;

  /// How long the app makes the user wait before Finish is enabled.
  final int minSeconds;
}

/// Same names and wording as `PHASES` in capture_ble.py (its line breaks are
/// folded into spaces).
const List<CapturePhase> capturePhases = [
  CapturePhase(
    'still',
    'Hold the controller still and upright: ring at the top, trigger facing '
        'away from you, as if aiming forward. Do not touch the buttons. Keep '
        'still for at least 5 seconds after pressing Enter.',
    minSeconds: 5,
  ),
  CapturePhase(
    'twist_cw',
    'Start upright and facing away, as above. Twist it about its handle, '
        'like tightening a screw: clockwise as seen from above. ONE full '
        '360-degree turn, slowly (about 4 seconds), ending in the same pose.',
  ),
  CapturePhase(
    'flip_away',
    'Start upright and facing away. Tip the top of the ring away from you '
        'and over: a forward somersault of the controller. ONE full '
        '360-degree turn, slowly (about 4 seconds), ending in the same pose.',
  ),
  CapturePhase(
    'lean_right',
    'Start upright and facing away. Tip the top of the ring to YOUR right '
        'and over: a cartwheel to the right. ONE full 360-degree turn, '
        'slowly (about 4 seconds), ending in the same pose.',
  ),
];

/// More than this fraction of frames lost makes a phase invalid for analysis.
const double captureLossyThreshold = 0.05;

/// Frame and sequence accounting for one hand over one phase. Port of
/// `LinkStats` in capture_ble.py, on integer microseconds.
class HandLinkStats {
  int frames = 0;
  int gapEvents = 0;
  int missing = 0;
  int outOfOrder = 0;
  int? _firstUs;
  int? _lastUs;
  int? _lastSeq;

  void add(int sequence, int atUs) {
    final last = _lastSeq;
    if (last != null) {
      final step = sequenceDelta(last, sequence);
      if (step <= 0) {
        outOfOrder++;
      } else if (step > 1) {
        gapEvents++;
        missing += step - 1;
      }
    }
    frames++;
    _lastSeq = sequence;
    _firstUs ??= atUs;
    _lastUs = atUs;
  }

  double get seconds =>
      frames > 1 ? (_lastUs! - _firstUs!) / Duration.microsecondsPerSecond : 0;
  int get produced => frames + missing;
  double get lossFraction => produced == 0 ? 0 : missing / produced;
  double get effectiveHz => seconds > 0 ? (frames - 1) / seconds : 0;
  double get producedHz => seconds > 0 ? (produced - 1) / seconds : 0;

  /// Same layout as `LinkStats.lines` in capture_ble.py.
  String line(String name) {
    final oo = outOfOrder > 0 ? '  out-of-order=$outOfOrder' : '';
    return '${name.padRight(5)} frames=$frames gaps=$gapEvents '
        'missing=$missing (${(100 * lossFraction).toStringAsFixed(1)}% lost) '
        'effective=${effectiveHz.toStringAsFixed(1)} Hz '
        'produced=${producedHz.toStringAsFixed(1)} Hz$oo';
  }
}

/// What one finished phase looked like on the link.
class PhaseSummary {
  const PhaseSummary(this.name, this.hands);

  final String name;

  /// Indexed by hand.
  final List<HandLinkStats> hands;

  double get worstLoss =>
      hands.map((h) => h.lossFraction).reduce((a, b) => a > b ? a : b);
  bool get lossy => worstLoss > captureLossyThreshold;
  int get totalFrames => hands.fold(0, (n, h) => n + h.frames);
}

/// Formats microseconds as seconds with 6 decimals, like Python's `%.6f`.
String formatCaptureSeconds(int us) {
  if (us < 0) us = 0;
  final frac = (us % Duration.microsecondsPerSecond).toString().padLeft(6, '0');
  return '${us ~/ Duration.microsecondsPerSecond}.$frac';
}

final List<String> _hex = [
  for (var i = 0; i < 256; i++) i.toRadixString(16).padLeft(2, '0'),
];

/// The capture file text for each kind of line.
class CaptureFormat {
  const CaptureFormat._();

  static const String version = 'wmr-capture v1';
  static const String source =
      'BLE FF11 raw stream via wmr_companion app (phone)';

  static String header({
    required int hand,
    required int? mtu,
    required DateTime started,
  }) {
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${started.year.toString().padLeft(4, '0')}-${two(started.month)}-'
        '${two(started.day)}T${two(started.hour)}:${two(started.minute)}:'
        '${two(started.second)}';
    return '# $version\n'
        '# source: $source\n'
        '# hand: ${handName(hand)} (as stated by the operator)\n'
        '# mtu: ${mtu ?? 'unknown'}\n'
        '# started: $stamp\n';
  }

  static String begin(String phase, int us) =>
      '@begin $phase t=${formatCaptureSeconds(us)}\n';

  static String end(String phase, int us) =>
      '@end $phase t=${formatCaptureSeconds(us)}\n';

  static String frame(int us, int hand, int sequence, List<int> data) {
    final b = StringBuffer('F ${formatCaptureSeconds(us)} $hand $sequence ');
    for (final byte in data) {
      b.write(_hex[byte]);
    }
    b.write('\n');
    return b.toString();
  }

  static String handName(int hand) => hand == wmrHandLeft ? 'LEFT' : 'RIGHT';

  /// `left-YYYYMMDD-HHMMSS.txt`
  static String fileName(int hand, DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${handName(hand).toLowerCase()}-'
        '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.txt';
  }
}

/// Number of bytes in a frame the analysis script accepts.
const int captureFrameLength = 46;

/// Writes one capture. Times are microseconds on the transport's monotonic
/// clock; the file shows them relative to [originUs]. Frames of both hands
/// are written (the analysis script picks one with `--hand`).
class CaptureRecorder {
  CaptureRecorder({
    required this.sink,
    required this.hand,
    required int? mtu,
    required DateTime started,
    required this.originUs,
  }) {
    sink.add(CaptureFormat.header(hand: hand, mtu: mtu, started: started));
  }

  final CaptureSink sink;
  final int hand;
  final int originUs;

  String? _phase;
  List<HandLinkStats>? _stats;

  /// Complete frames that were not 46 bytes long, so were not written.
  int skippedFrames = 0;

  final List<PhaseSummary> summaries = [];

  bool get recording => _phase != null;
  String? get currentPhase => _phase;

  void beginPhase(String name, int atUs) {
    assert(_phase == null, 'phase already running');
    _phase = name;
    _stats = [for (var i = 0; i < wmrNumControllers; i++) HandLinkStats()];
    sink.add(CaptureFormat.begin(name, atUs - originUs));
  }

  /// Frames outside a phase are dropped, as in the desktop tool.
  void addFrame(ReceivedFrame received) {
    final stats = _stats;
    if (_phase == null || stats == null) return;
    final frame = received.frame;
    if (frame.length != captureFrameLength) {
      skippedFrames++;
      return;
    }
    stats[frame.hand].add(frame.sequence, received.receivedAtUs);
    sink.add(
      CaptureFormat.frame(
        received.receivedAtUs - originUs,
        frame.hand,
        frame.sequence,
        frame.data,
      ),
    );
  }

  PhaseSummary endPhase(int atUs) {
    final name = _phase!;
    sink.add(CaptureFormat.end(name, atUs - originUs));
    final summary = PhaseSummary(name, _stats!);
    summaries.add(summary);
    _phase = null;
    _stats = null;
    return summary;
  }

  Future<void> close() => sink.close();
}
