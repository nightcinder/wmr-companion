// Replays anchor captures through ONY-501's `filter-spec` rev 4 grid and
// reports the ONY-502 metrics. Run it from packages/wmr_tracking:
//
//   dart run tool/pose_filter_tune.dart
//
// Defaults read the committed fixtures in
// test/fixtures/pose_filter_captures/synthetic and write
// build/pose_filter_tune.json. Exit 0 means every runtime passed, 1 means a
// runtime failed or no point passed, 3 means a winner landed on a grid
// boundary after the 50 % extension and the result is inconclusive.
import 'dart:convert';
import 'dart:io';

import 'package:wmr_tracking/wmr_tracking.dart';

import 'src/pose_filter_tuning.dart';

const String _defaultCaptures = 'test/fixtures/pose_filter_captures/synthetic';
const String _defaultOutput = 'build/pose_filter_tune.json';
const String _usage =
    'usage: dart run tool/pose_filter_tune.dart '
    '[--captures <dir>] [--output <path>] [--markdown <path>]';

/// The pre-ONY-502 paper defaults, kept for the before column.
const PoseFilterConfig _paperDefaults = PoseFilterConfig(
  minCutoffHz: 1.0,
  beta: 0.02,
  dCutoffHz: 1.0,
  minDt: Duration(microseconds: 4167),
);

void main(List<String> args) {
  var capturesPath = _defaultCaptures;
  var output = _defaultOutput;
  String? markdown;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--captures' && i + 1 < args.length) {
      capturesPath = args[++i];
    } else if (arg.startsWith('--captures=')) {
      capturesPath = arg.substring('--captures='.length);
    } else if (arg == '--output' && i + 1 < args.length) {
      output = args[++i];
    } else if (arg.startsWith('--output=')) {
      output = arg.substring('--output='.length);
    } else if (arg == '--markdown' && i + 1 < args.length) {
      markdown = args[++i];
    } else if (arg.startsWith('--markdown=')) {
      markdown = arg.substring('--markdown='.length);
    } else if (arg == '--help' || arg == '-h') {
      stdout.writeln(_usage);
      return;
    } else {
      _fail('unknown argument: $arg', 2);
      return;
    }
  }

  final captures = _load(capturesPath);
  if (captures.isEmpty) {
    _fail('no captures in $capturesPath', 2);
    return;
  }
  final reports = tunePoseFilter(captures);
  final perCapture = _perCapture(captures);
  final json = {
    'spec': 'filter-spec rev 4',
    'thresholds': {
      'jitter_mm': poseFilterJitterLimitMm,
      'drift_jitter_mm': poseFilterDriftJitterLimitMm,
      'lag_median_ms': poseFilterLagLimitMs,
      'slow_lag_median_ms': poseFilterSlowLagLimitMs,
    },
    'grid': PoseGrid.standard.toJson(),
    'capture_dir': capturesPath,
    'captures': captures.length,
    'paper_defaults': _paperDefaults.toJson(),
    'tuned_defaults': const PoseFilterConfig().toJson(),
    'per_capture': perCapture,
    'runtimes': [for (final report in reports) report.toJson()],
  };

  final file = File(output);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  if (markdown != null) {
    final md = File(markdown);
    md.parent.createSync(recursive: true);
    md.writeAsStringSync(_markdown(reports, captures.length));
  }

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'output': output,
      if (markdown != null) 'markdown': markdown,
      'captures': captures.length,
      'runtimes': [
        for (final report in reports)
          {
            'runtime': report.runtime.name,
            'passed': report.passed,
            'inconclusive': report.inconclusive,
            'missing_motions': report.missingMotions,
            'raw_jitter_mm': report.rawJitterMm,
            'chosen': report.chosen?.point.toJson(),
            'jitter_mm': report.chosen?.jitterMm,
            'jitter_drift_mm': report.chosen?.jitterDriftMm,
            'lag_median_ms': report.chosen?.lagMedianMs,
            'lag_slow_median_ms': report.chosen?.lagSlowMedianMs,
          },
      ],
    }),
  );
  if (reports.any((report) => report.inconclusive)) {
    exitCode = 3;
  } else {
    exitCode = reports.every((report) => report.passed) ? 0 : 1;
  }
}

List<PoseCapture> _load(String path) {
  final directory = Directory(path);
  if (!directory.existsSync()) return const [];
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files) PoseCapture.decode(file.readAsStringSync()),
  ];
}

List<Map<String, Object?>> _perCapture(List<PoseCapture> captures) {
  final rows = <Map<String, Object?>>[];
  for (final capture in captures) {
    final before = analyzeCapture(capture, _paperDefaults, includePeak: true);
    final after = analyzeCapture(
      capture,
      const PoseFilterConfig(),
      includePeak: true,
    );
    rows.add({
      'runtime': capture.runtime.name,
      'motion': capture.motion.name,
      'run': capture.run,
      'synthetic': capture.synthetic,
      'before': before.toJson(),
      'after': after.toJson(),
    });
  }
  return rows;
}

String _markdown(List<TuningReport> reports, int captureCount) {
  final buffer = StringBuffer()
    ..writeln('# Pose filter tuning grid (ONY-502)')
    ..writeln()
    ..writeln(
      'Generated by `dart run tool/pose_filter_tune.dart`. '
      '$captureCount captures.',
    )
    ..writeln()
    ..writeln(
      'Normative spec: `filter-spec` rev 4, section 7. '
      'Grid: minCutoff 1.0-4.0 Hz step 0.25, beta 0.00-0.40 Hz per cm/s '
      'step 0.01, dCutoff 0.5-4.0 Hz step 0.5. '
      '${PoseGrid.standard.pointCount} points per runtime, all replayed; '
      'no early stop and no pruning.',
    )
    ..writeln()
    ..writeln(
      'Bars: J <= ${poseFilterJitterLimitMm} mm, '
      'J_D <= ${poseFilterDriftJitterLimitMm} mm, '
      'median L <= ${poseFilterLagLimitMs} ms on medium and fast sweeps, '
      'median L <= ${poseFilterSlowLagLimitMs} ms on slow sweeps '
      '(regression only). Selected point: lowest J_D, then lowest median L.',
    )
    ..writeln()
    ..writeln(
      'A winner on a bar-limiting boundary is inconclusive. The tool '
      'extends that axis 50 % at the same step and reruns the whole grid.',
    );
  for (final report in reports) {
    buffer
      ..writeln()
      ..writeln('## ${report.runtime.name}')
      ..writeln()
      ..writeln(
        report.bypass
            ? 'Raw input already meets the jitter bound; bypass the filter.'
            : report.inconclusive
            ? '**Inconclusive:** the extended grid still selects a point on a '
                  'bar-limiting boundary. Escalate to ONY-501 with both grids.'
            : report.chosen == null
            ? '**No point passes.** Escalate to ONY-501.'
            : 'Chosen: ${report.chosen!.point}. '
                  'Jitter ${report.chosen!.jitterMm.toStringAsFixed(3)} mm, '
                  'J_D ${report.chosen!.jitterDriftMm.toStringAsFixed(3)} mm, '
                  'lag ${report.chosen!.lagMedianMs.toStringAsFixed(1)} ms.',
      );
    if (report.missingMotions.isNotEmpty) {
      buffer.writeln(
        'Missing motion classes: ${report.missingMotions.join(', ')}.',
      );
    }
    _writeGridTable(buffer, report.rows);
    final extension = report.extension;
    if (extension != null) {
      buffer
        ..writeln()
        ..writeln('### Extended rerun')
        ..writeln()
        ..writeln(
          'minCutoff ${extension.grid.minCutoff.min}-'
          '${extension.grid.minCutoff.max}, beta ${extension.grid.beta.min}-'
          '${extension.grid.beta.max}, dCutoff '
          '${extension.grid.dCutoff.min}-${extension.grid.dCutoff.max}.',
        );
      _writeGridTable(buffer, extension.rows);
    }
  }
  return buffer.toString();
}

void _writeGridTable(StringBuffer buffer, List<TuningRow> rows) {
  buffer
    ..writeln()
    ..writeln(
      '| minCutoff Hz | beta | dCutoff Hz | J mm | J_D mm | L slow ms | '
      'L median ms | step 90 % ms | pass |',
    )
    ..writeln('|---:|---:|---:|---:|---:|---:|---:|---:|:---:|');
  for (final row in rows) {
    buffer.writeln(
      '| ${row.point.minCutoffHz} | ${row.point.beta} | '
      '${row.point.dCutoffHz} | ${row.jitterMm.toStringAsFixed(3)} | '
      '${row.jitterDriftMm.toStringAsFixed(3)} | '
      '${row.lagSlowMedianMs.toStringAsFixed(1)} | '
      '${row.lagMedianMs.toStringAsFixed(1)} | '
      '${row.step90Ms.toStringAsFixed(1)} | '
      '${row.passes ? "yes" : ""} |',
    );
  }
}

void _fail(String message, int code) {
  stderr.writeln(jsonEncode({'error': message}));
  exitCode = code;
}
