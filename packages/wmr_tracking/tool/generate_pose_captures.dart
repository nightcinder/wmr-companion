// Generates the deterministic synthetic anchor captures used by the ONY-502
// filter tuner. Run it from packages/wmr_tracking:
//
//   dart run tool/generate_pose_captures.dart
//
// The output is committed under test/fixtures/pose_filter_captures/synthetic.
// These are placeholders with stated provenance, not hardware results: the
// ONY-249 recorder can produce real captures in the app, and
// `PoseCapture.fromRecording` feeds them to the same tuner.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import 'src/pose_filter_tuning.dart';

const String _defaultOutput = 'test/fixtures/pose_filter_captures/synthetic';

const Map<TrackingVendor, int> _anchorRates = {
  TrackingVendor.androidXr: 60,
  TrackingVendor.xreal: 60,
  TrackingVendor.viture: 25,
};

const double _noiseSigmaM = 0.0005;
const int _runsPerCell = 4;

void main(List<String> args) {
  var output = _defaultOutput;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--out' && i + 1 < args.length) {
      output = args[++i];
    } else if (arg.startsWith('--out=')) {
      output = arg.substring('--out='.length);
    } else if (arg == '--help' || arg == '-h') {
      stdout.writeln(
        'usage: dart run tool/generate_pose_captures.dart [--out <dir>]',
      );
      return;
    } else {
      stderr.writeln(jsonEncode({'error': 'unknown argument: $arg'}));
      exitCode = 2;
      return;
    }
  }

  final directory = Directory(output)..createSync(recursive: true);
  var written = 0;
  for (final entry in _anchorRates.entries) {
    for (final motion in PoseMotion.values) {
      for (var run = 1; run <= _runsPerCell; run++) {
        final capture = _capture(entry.key, entry.value, motion, run);
        final name = '${entry.key.name}-${motion.name}-$run.json';
        File('${directory.path}/$name').writeAsStringSync(capture.encode());
        written++;
      }
    }
  }
  stdout.writeln(
    jsonEncode({'format': 'generated', 'files': written, 'dir': output}),
  );
}

PoseCapture _capture(
  TrackingVendor runtime,
  int rateHz,
  PoseMotion motion,
  int run,
) {
  final seed = 502000 + runtime.index * 1000 + motion.index * 100 + run;
  final random = math.Random(seed);
  final (durationS, gapS) = switch (motion) {
    PoseMotion.occlusion => (30.0, 10.0),
    // `filter-spec` rev 4 section 8: slow pan is 3 x 6 s.
    PoseMotion.slowPan => (18.0, 0.0),
    _ => (10.0, 0.0),
  };
  final dt = 1 / rateHz;
  final origin = 1000000000;
  final samples = <PoseCaptureSample>[];
  var t = 0.0;
  while (t <= durationS) {
    // A 150 ms dropout in the middle of the occlusion capture.
    final inGap =
        motion == PoseMotion.occlusion && t >= gapS && t < gapS + 0.150;
    if (!inGap) {
      final base = _motionOffset(motion, t);
      final noise = Vector3(
        _gaussian(random) * _noiseSigmaM,
        _gaussian(random) * _noiseSigmaM,
        _gaussian(random) * _noiseSigmaM,
      );
      final timeNs =
          origin + (t * 1000000000).round() + _timeJitter(random, dt);
      samples.add(
        PoseCaptureSample(
          timeNs: samples.isEmpty
              ? timeNs
              : math.max(timeNs, samples.last.timeNs + 1),
          position: Vector3(0.2, -0.25, -0.35) + base + noise,
        ),
      );
    }
    t += dt;
  }
  return PoseCapture(
    runtime: runtime,
    motion: motion,
    run: run,
    provenance: {
      'kind': 'synthetic',
      'generator': 'tool/generate_pose_captures.dart',
      'seed': seed,
      'anchor_rate_hz': rateHz,
      'noise_sigma_mm': _noiseSigmaM * 1000,
      'speeds_m_s': _speedBands,
      'app_commit': null,
      'firmware_sha': null,
      'note':
          'Synthetic placeholder for filter-spec rev 4. Replace with an '
          'ONY-249 app recording before treating these numbers as hardware '
          'results.',
    },
    samples: samples,
  );
}

/// Nominal speeds from `filter-spec` rev 4 section 8.
const Map<String, double> _speedBands = {
  'still': 0,
  'heldDrift': 0.2,
  'slowPan': 0.10,
  'mediumPan': 0.50,
  'fastFlick': 1.50,
};

Vector3 _motionOffset(PoseMotion motion, double t) {
  return switch (motion) {
    PoseMotion.still => Vector3.zero(),
    PoseMotion.heldDrift => _drift(t),
    PoseMotion.slowPan => Vector3(
      _sweep(t, amplitude: 0.10, speed: 0.10),
      0,
      0,
    ),
    PoseMotion.mediumPan => Vector3(
      _sweep(t, amplitude: 0.25, speed: 0.50),
      0,
      0,
    ),
    PoseMotion.fastFlick => Vector3(_flick(t), 0, 0),
    PoseMotion.occlusion => Vector3(
      _sweep(t, amplitude: 0.10, speed: 0.08),
      0,
      0,
    ),
  };
}

/// Segment D: held as if aiming, wandering at 10-50 cm/s. The wander is slow
/// enough that a 1 s quadratic fit removes the trend and leaves the jitter.
Vector3 _drift(double t) => Vector3(
  0.25 * math.sin(2 * math.pi * 0.10 * t) +
      0.08 * math.sin(2 * math.pi * 0.17 * t + 0.7) +
      0.02 * math.sin(2 * math.pi * 0.05 * t + 2.0),
  0.12 * math.sin(2 * math.pi * 0.13 * t + 1.1),
  0.05 * math.sin(2 * math.pi * 0.08 * t + 2.4),
);

/// Sinusoid whose peak speed is [speed] m/s.
double _sweep(double t, {required double amplitude, required double speed}) {
  final frequency = speed / (2 * math.pi * amplitude);
  return amplitude * math.sin(2 * math.pi * frequency * t);
}

/// Ten out-and-back 0.45 m flicks at a 1.5 m/s peak, one per second.
double _flick(double t) {
  final phase = t - (t / 1.0).floorToDouble();
  double move(double at) => 0.5 * (1 + _tanh((phase - at) / 0.15));
  return 0.45 * (move(0.10) - move(0.55));
}

double _tanh(double value) {
  final e = math.exp(2 * value);
  return (e - 1) / (e + 1);
}

int _timeJitter(math.Random random, double dt) {
  final span = (dt * 1000000000 * 0.2).round();
  return random.nextInt(span * 2 + 1) - span;
}

double _gaussian(math.Random random) {
  final u1 = 1 - random.nextDouble();
  final u2 = random.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}
