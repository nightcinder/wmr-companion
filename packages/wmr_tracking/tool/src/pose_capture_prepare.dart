// Converts ONY-249 `PoseRecording` files into the `wmr-pose-capture` v1
// traces the ONY-502 pose-filter tuner replays, and checks the corpus against
// `filter-spec` rev 4 section 8 before any constants are chosen.
//
// Two inputs are accepted, because a tester sends one and the app leaves the
// other on disk:
//
// - a tester bundle (the zip the companion exports), whose `diagnostics.json`
//   names each pose file's runtime, hand, segment and run;
// - a directory of `PoseRecording` JSON files, whose `provenance` block carries
//   the same labels (the guided bench writes them).
//
// The output tree is `<runtime>/<hand>/<motion>/run<N>.json`. The motion lives
// in the capture document; the two directory levels above it keep left and
// right hand traces apart for coverage even though the tuner pools them per
// runtime.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

import 'pose_filter_tuning.dart';

/// `filter-spec` rev 4 section 8 corpus: five scored classes and one
/// diagnostic class, four runs per scored class per hand and per runtime.
class PoseCorpusPlan {
  const PoseCorpusPlan({
    this.runsPerClass = 4,
    this.occlusionRuns = 1,
    this.minimumRunSeconds = 30,
  });

  /// Section 8: "at least four runs per motion class per runtime".
  final int runsPerClass;

  /// Section 8 gives occlusion no bar, and the app records one run per hand.
  final int occlusionRuns;

  /// Section 8: every run is "at least 30 s" of anchor samples. A shorter file
  /// is a named deficiency, never a run that satisfies a cell.
  final int minimumRunSeconds;

  static const List<PoseMotion> scored = [
    PoseMotion.still,
    PoseMotion.heldDrift,
    PoseMotion.slowPan,
    PoseMotion.mediumPan,
    PoseMotion.fastFlick,
  ];

  static const List<PoseMotion> motions = [...scored, PoseMotion.occlusion];

  /// Short names the coverage matrix uses: S, D, slow, M, F, occ.
  static String column(PoseMotion motion) => switch (motion) {
    PoseMotion.still => 'S',
    PoseMotion.heldDrift => 'D',
    PoseMotion.slowPan => 'slow',
    PoseMotion.mediumPan => 'M',
    PoseMotion.fastFlick => 'F',
    PoseMotion.occlusion => 'occ',
  };

  int requiredFor(PoseMotion motion) =>
      motion == PoseMotion.occlusion ? occlusionRuns : runsPerClass;

  Duration get minimumRun => Duration(seconds: minimumRunSeconds);

  Map<String, Object?> toJson() => {
    'runs_per_class': runsPerClass,
    'occlusion_runs': occlusionRuns,
    'minimum_run_seconds': minimumRunSeconds,
  };
}

/// The four labels a corpus cell is keyed by.
class CaptureLabels {
  const CaptureLabels({
    required this.runtime,
    required this.hand,
    required this.motion,
    required this.run,
    this.source,
  });

  final TrackingVendor runtime;
  final TrackedHand hand;
  final PoseMotion motion;
  final int run;

  /// Where the labels came from, for the error message: `provenance` or
  /// `diagnostics.json`.
  final String? source;

  String get cell => '${runtime.name}/${hand.name}/${motion.name}';
}

/// A recording read from a bundle or a directory, plus any labels the bundle
/// carried separately from the recording.
class RecordingInput {
  const RecordingInput({
    required this.fileName,
    required this.recording,
    this.bundleLabels,
  });

  /// Base name of the pose file, kept in the capture provenance.
  final String fileName;

  final PoseRecording recording;

  /// Labels from the bundle's `diagnostics.json`, when there is one.
  final CaptureLabels? bundleLabels;
}

/// One converted capture and where it belongs under the output root.
class PreparedCapture {
  const PreparedCapture({
    required this.relativePath,
    required this.capture,
    required this.labels,
  });

  final String relativePath;
  final PoseCapture capture;

  /// The cell this capture was placed in.
  final CaptureLabels labels;

  /// Wall time covered by the trace: last sample minus first sample. Section 8
  /// asks for at least 30 s, so a file count alone does not prove coverage.
  Duration get span => Duration(
    microseconds:
        (capture.samples.last.timeNs - capture.samples.first.timeNs) ~/ 1000,
  );
}

/// A run whose samples cover less than the section 8 minimum.
class ShortRun {
  const ShortRun({
    required this.labels,
    required this.span,
    required this.minimum,
  });

  final CaptureLabels labels;
  final Duration span;
  final Duration minimum;

  String get description =>
      '${labels.cell}: run ${labels.run} is '
      '${(span.inMilliseconds / 1000).toStringAsFixed(1)} s, needs '
      '${minimum.inSeconds} s';
}

/// How many runs one `(runtime, hand, motion)` cell has.
class CoverageCell {
  const CoverageCell({
    required this.runtime,
    required this.hand,
    required this.motion,
    required this.runs,
    required this.requiredRuns,
  });

  final TrackingVendor runtime;
  final TrackedHand hand;
  final PoseMotion motion;
  final int runs;
  final int requiredRuns;

  bool get complete => runs >= requiredRuns;

  String get description =>
      '${runtime.name}/${hand.name}/${motion.name}: '
      '$runs of $requiredRuns runs';
}

/// The section 8 coverage matrix for one corpus.
class CorpusCoverage {
  const CorpusCoverage({
    required this.plan,
    required this.cells,
    this.shortRuns = const [],
  });

  final PoseCorpusPlan plan;

  /// One entry per `(runtime, hand, motion)`, sorted for stable output.
  final List<CoverageCell> cells;

  /// Runs that exist but cover less than the section 8 minimum duration.
  final List<ShortRun> shortRuns;

  Iterable<CoverageCell> get incomplete =>
      cells.where((cell) => !cell.complete);

  bool get isComplete => incomplete.isEmpty && shortRuns.isEmpty;

  List<String> get missingCells => [
    for (final cell in incomplete) cell.description,
    for (final run in shortRuns) run.description,
  ];

  /// Every runtime present in the corpus, in name order.
  List<TrackingVendor> get runtimes {
    final seen = <TrackingVendor>{for (final cell in cells) cell.runtime};
    return seen.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Runs recorded in [runtime] and [hand] for [motion].
  int runs(TrackingVendor runtime, TrackedHand hand, PoseMotion motion) {
    for (final cell in cells) {
      if (cell.runtime == runtime &&
          cell.hand == hand &&
          cell.motion == motion) {
        return cell.runs;
      }
    }
    return 0;
  }

  /// The matrix as a markdown table, one row per runtime and hand.
  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('| Runtime | Hand | S | D | slow | M | F | occ |')
      ..writeln('|---|---|---:|---:|---:|---:|---:|---:|');
    for (final runtime in runtimes) {
      for (final hand in TrackedHand.values) {
        buffer.write('| ${runtime.name} | ${hand.name} |');
        for (final motion in PoseCorpusPlan.motions) {
          final runs = this.runs(runtime, hand, motion);
          final required = plan.requiredFor(motion);
          final mark = runs >= required ? '' : ' **missing**';
          buffer.write(' $runs/$required$mark |');
        }
        buffer.writeln();
      }
    }
    return buffer.toString();
  }
}

/// A converted corpus: the captures to write and the coverage that justifies
/// them.
class PreparedCorpus {
  const PreparedCorpus({
    required this.plan,
    required this.captures,
    required this.coverage,
  });

  final PoseCorpusPlan plan;
  final List<PreparedCapture> captures;
  final CorpusCoverage coverage;

  bool get isComplete => coverage.isComplete;

  List<String> get missingCells => coverage.missingCells;

  /// Relative paths written under the output root.
  List<String> get paths => [
    for (final capture in captures) capture.relativePath,
  ];

  /// Writes every capture and a `coverage.md` summary under [root].
  void writeTo(Directory root) {
    for (final prepared in captures) {
      final separator = Platform.pathSeparator;
      final file = File(
        '${root.path}$separator'
        '${prepared.relativePath.replaceAll('/', separator)}',
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(prepared.capture.encode());
    }
    File('${root.path}${Platform.pathSeparator}coverage.md')
        .writeAsStringSync(coverage.toMarkdown());
  }
}

/// A bundle or directory that cannot be converted, with the reason a tester or
/// reviewer can act on.
class PosePrepareException implements Exception {
  const PosePrepareException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'PosePrepareException: $message';
}

/// `pose_capture_<runtime>_<hand>_<segment>[_runN].json`.
final RegExp _fileNamePattern = RegExp(
  r'^pose_capture_([A-Za-z0-9]+)_(left|right)_(.+?)(?:_run(\d+))?\.json$',
);

/// Segment ids the guided bench writes, plus the [PoseMotion] names a prepared
/// capture uses.
const Map<String, PoseMotion> poseMotionBySegment = {
  'still': PoseMotion.still,
  'drifting': PoseMotion.heldDrift,
  'heldDrift': PoseMotion.heldDrift,
  'slow_pan': PoseMotion.slowPan,
  'slowPan': PoseMotion.slowPan,
  'medium_pan': PoseMotion.mediumPan,
  'mediumPan': PoseMotion.mediumPan,
  'fast_flick': PoseMotion.fastFlick,
  'fastFlick': PoseMotion.fastFlick,
  'occlusion': PoseMotion.occlusion,
};

/// Labels from `pose_capture_<runtime>_<hand>_<segment>[_runN].json`, or null
/// when the name does not follow the bundle convention.
CaptureLabels? labelsFromFileName(String fileName) {
  final match = _fileNamePattern.firstMatch(fileName);
  if (match == null) return null;
  final segment = poseMotionBySegment[match.group(3)];
  final runtime = _vendorNamed(match.group(1)!);
  final run = int.tryParse(match.group(4) ?? '1') ?? 1;
  // `run0` would decode to a capture the tuner rejects (`run < 1`).
  if (segment == null || runtime == null || run < 1) return null;
  return CaptureLabels(
    runtime: runtime,
    hand: TrackedHand.values.firstWhere((hand) => hand.name == match.group(2)),
    motion: segment,
    run: run,
    source: 'file name',
  );
}

/// Labels from the guided bench's provenance block.
///
/// A debug-screen recording has no provenance and cannot be placed in a cell;
/// the caller then falls back to the file name.
CaptureLabels? labelsFromProvenance(PoseRecording recording) {
  final provenance = recording.provenance;
  final runtimeName = provenance['runtime'];
  final handName = provenance['hand'];
  final motionName = provenance['motion'];
  final run = provenance['run_index'];
  if (runtimeName is! String || handName is! String || motionName is! String) {
    return null;
  }
  final runtime = _vendorNamed(runtimeName);
  final hand = _handNamed(handName);
  final motion = poseMotionBySegment[motionName];
  if (runtime == null || hand == null || motion == null) return null;
  return CaptureLabels(
    runtime: runtime,
    hand: hand,
    motion: motion,
    run: run is int && run > 0 ? run : 1,
    source: 'provenance',
  );
}

/// Resolves the labels of one input, preferring the bundle manifest, then the
/// recording provenance, then the file name.
CaptureLabels resolveLabels(RecordingInput input) {
  final labels =
      input.bundleLabels ??
      labelsFromProvenance(input.recording) ??
      labelsFromFileName(input.fileName);
  if (labels == null) {
    throw PosePrepareException(
      '${input.fileName}: cannot place this recording. Its provenance has no '
      'runtime/hand/motion and its name is not '
      'pose_capture_<runtime>_<hand>_<segment>[_runN].json.',
    );
  }
  return labels;
}

/// Converts [inputs] into `wmr-pose-capture` v1 traces and checks the section
/// 8 coverage. The corpus is still returned when it is incomplete, so the CLI
/// can print the exact missing cells and write nothing.
PreparedCorpus prepareCorpus(
  List<RecordingInput> inputs, {
  PoseCorpusPlan plan = const PoseCorpusPlan(),
}) {
  final byCell = <String, PreparedCapture>{};
  for (final input in inputs) {
    final labels = resolveLabels(input);
    final key = '${labels.cell}:${labels.run}';
    final previous = byCell[key];
    if (previous != null) {
      throw PosePrepareException(
        '${input.fileName}: duplicate cell ${labels.cell} run ${labels.run}; '
        'the same cell and run already came from '
        '${previous.capture.provenance['source_file']}.',
      );
    }
    final PoseCapture capture;
    try {
      capture = PoseCapture.fromRecording(
        input.recording,
        runtime: labels.runtime,
        motion: labels.motion,
        run: labels.run,
        hand: labels.hand,
        provenance: {
          ...input.recording.provenance,
          'source_file': input.fileName,
          'prepared_by': 'tool/pose_capture_prepare.dart',
        },
      );
    } on PoseCaptureException catch (error) {
      throw PosePrepareException('${input.fileName}: ${error.message}', error);
    }
    byCell[key] = PreparedCapture(
      relativePath:
          '${labels.runtime.name}/${labels.hand.name}/${labels.motion.name}/'
          'run${labels.run}.json',
      capture: capture,
      labels: labels,
    );
  }

  final minimum = plan.minimumRun;
  final shortRuns =
      byCell.values
          .where((prepared) => prepared.span < minimum)
          .map(
            (prepared) => ShortRun(
              labels: prepared.labels,
              span: prepared.span,
              minimum: minimum,
            ),
          )
          .toList()
        ..sort((a, b) => a.description.compareTo(b.description));

  final cells = <CoverageCell>[];
  final runtimes = {
    for (final prepared in byCell.values) prepared.capture.runtime,
  }.toList()..sort((a, b) => a.name.compareTo(b.name));
  for (final runtime in runtimes) {
    for (final hand in TrackedHand.values) {
      for (final motion in PoseCorpusPlan.motions) {
        final runs = byCell.values
            .where(
              (prepared) =>
                  prepared.labels.runtime == runtime &&
                  prepared.labels.hand == hand &&
                  prepared.labels.motion == motion &&
                  prepared.span >= minimum,
            )
            .length;
        cells.add(
          CoverageCell(
            runtime: runtime,
            hand: hand,
            motion: motion,
            runs: runs,
            requiredRuns: plan.requiredFor(motion),
          ),
        );
      }
    }
  }

  final captures = byCell.values.toList()
    ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return PreparedCorpus(
    plan: plan,
    captures: captures,
    coverage: CorpusCoverage(plan: plan, cells: cells, shortRuns: shortRuns),
  );
}

/// Reads every placeable `PoseRecording` in [directory].
///
/// A folder can also hold debug-screen recordings (`pose-<timestamp>.json`)
/// that carry no provenance and do not follow the corpus file-name convention.
/// Those are reported through [onSkip] and left out instead of failing the
/// whole conversion.
List<RecordingInput> readRecordingDirectory(
  Directory directory, {
  void Function(String fileName)? onSkip,
}) {
  if (!directory.existsSync()) {
    throw PosePrepareException('no such directory: ${directory.path}');
  }
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final inputs = <RecordingInput>[];
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    PoseRecording recording;
    try {
      recording = PoseRecording.decode(file.readAsStringSync());
    } on PoseRecordingException catch (error) {
      // A directory may hold diagnostics or a bench progress file; only a
      // document that claims to be a recording is an error.
      if (error.error == PoseRecordingError.invalidDocument &&
          !_looksLikeRecording(file)) {
        continue;
      }
      throw PosePrepareException('$name: ${error.message}', error);
    }
    if (labelsFromProvenance(recording) == null &&
        labelsFromFileName(name) == null) {
      onSkip?.call(name);
      continue;
    }
    inputs.add(RecordingInput(fileName: name, recording: recording));
  }
  if (inputs.isEmpty) {
    throw PosePrepareException(
      'no pose recordings in ${directory.path}; expected PoseRecording JSON '
      'files.',
    );
  }
  return inputs;
}

/// Reads the pose files out of a tester bundle zip.
List<RecordingInput> readTesterBundle(File bundle) {
  if (!bundle.existsSync()) {
    throw PosePrepareException('no such bundle: ${bundle.path}');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bundle.readAsBytesSync());
  } on ArchiveException catch (error) {
    throw PosePrepareException('${bundle.path}: ${error.message}', error);
  }
  final labelsByName = _bundleLabels(archive);
  final inputs = <RecordingInput>[];
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name.split('/').last;
    if (!name.endsWith('.json')) continue;
    final labels = labelsByName[name];
    if (labels == null && !name.startsWith('pose_capture_')) continue;
    final PoseRecording recording;
    try {
      recording = PoseRecording.decode(utf8.decode(file.content));
    } on PoseRecordingException catch (error) {
      throw PosePrepareException('$name: ${error.message}', error);
    }
    inputs.add(
      RecordingInput(
        fileName: name,
        recording: recording,
        bundleLabels: labels,
      ),
    );
  }
  if (inputs.isEmpty) {
    throw PosePrepareException(
      'no pose files in ${bundle.path}; expected pose_capture_*.json at the '
      'archive root.',
    );
  }
  inputs.sort((a, b) => a.fileName.compareTo(b.fileName));
  return inputs;
}

/// Labels from the bundle's `diagnostics.json` `pose_captures` list.
Map<String, CaptureLabels> _bundleLabels(Archive archive) {
  for (final file in archive.files) {
    if (!file.isFile || file.name.split('/').last != 'diagnostics.json') {
      continue;
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(file.content));
    } on FormatException catch (error) {
      throw PosePrepareException(
        'diagnostics.json: not valid JSON: ${error.message}',
        error,
      );
    }
    if (json is! Map) return const {};
    final rows = json['pose_captures'];
    if (rows is! List) return const {};
    final labels = <String, CaptureLabels>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final name = row['file'];
      final runtimeName = row['runtime'];
      final handName = row['hand'];
      final segment = row['segment'];
      if (name is! String ||
          runtimeName is! String ||
          handName is! String ||
          segment is! String) {
        continue;
      }
      final runtime = _vendorNamed(runtimeName);
      final hand = _handNamed(handName);
      final motion = poseMotionBySegment[segment];
      if (runtime == null || hand == null || motion == null) continue;
      final run = row['run'];
      labels[name.split('/').last] = CaptureLabels(
        runtime: runtime,
        hand: hand,
        motion: motion,
        run: run is int && run > 0 ? run : 1,
        source: 'diagnostics.json',
      );
    }
    return labels;
  }
  return const {};
}

TrackingVendor? _vendorNamed(String name) {
  for (final vendor in TrackingVendor.values) {
    if (vendor.name == name) return vendor;
  }
  return null;
}

TrackedHand? _handNamed(String name) {
  final lower = name.toLowerCase();
  for (final hand in TrackedHand.values) {
    if (hand.name == lower) return hand;
  }
  return null;
}

/// Whether a file at least claims the recording format, used to tell an
/// unsupported document from an unrelated JSON file in the same directory.
bool _looksLikeRecording(File file) {
  try {
    final json = jsonDecode(file.readAsStringSync());
    return json is Map && json['format'] == PoseRecording.format;
  } on FormatException {
    return false;
  }
}
