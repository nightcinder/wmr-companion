// Turns a tester bundle, or a directory of ONY-249 `PoseRecording` files, into
// the `wmr-pose-capture` v1 corpus the ONY-502 tuner replays. Run it from
// packages/wmr_tracking:
//
//   dart run tool/pose_capture_prepare.dart --bundle wmr-ext-20261030.zip
//   dart run tool/pose_capture_prepare.dart --captures path/to/recordings
//
// It writes <out>/<runtime>/<hand>/<motion>/run<N>.json and <out>/coverage.md,
// prints the `filter-spec` rev 4 section 8 coverage matrix, and refuses a
// corpus that does not cover every runtime/hand/class cell with runs of at
// least 30 s. Exit 0 means the corpus is complete and written, 1 means it was
// refused as incomplete, 2 means bad arguments or unreadable input.
import 'dart:convert';
import 'dart:io';

import 'src/pose_capture_prepare.dart';

const String _defaultOutput = 'build/pose_corpus';
const String _usage =
    'usage: dart run tool/pose_capture_prepare.dart '
    '(--bundle <zip> | --captures <dir>) [--out <dir>]';

void main(List<String> args) {
  String? bundle;
  String? captures;
  var output = _defaultOutput;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--bundle' && i + 1 < args.length) {
      bundle = args[++i];
    } else if (arg.startsWith('--bundle=')) {
      bundle = arg.substring('--bundle='.length);
    } else if (arg == '--captures' && i + 1 < args.length) {
      captures = args[++i];
    } else if (arg.startsWith('--captures=')) {
      captures = arg.substring('--captures='.length);
    } else if (arg == '--out' && i + 1 < args.length) {
      output = args[++i];
    } else if (arg.startsWith('--out=')) {
      output = arg.substring('--out='.length);
    } else if (arg == '--help' || arg == '-h') {
      stdout.writeln(_usage);
      return;
    } else {
      _fail('unknown argument: $arg', 2);
      return;
    }
  }
  if ((bundle == null) == (captures == null)) {
    _fail('give exactly one of --bundle or --captures\n$_usage', 2);
    return;
  }

  final PreparedCorpus corpus;
  try {
    final inputs = bundle != null
        ? readTesterBundle(File(bundle))
        : readRecordingDirectory(
            Directory(captures!),
            onSkip: (name) => stderr.writeln(
              'warning: skipped $name; no provenance and not '
              'pose_capture_<runtime>_<hand>_<segment>[_runN].json',
            ),
          );
    corpus = prepareCorpus(inputs);
  } on PosePrepareException catch (error) {
    _fail(error.message, 2);
    return;
  }

  stdout.writeln(corpus.coverage.toMarkdown());
  if (!corpus.isComplete) {
    exitCode = 1;
    stderr.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'error': 'incomplete corpus; nothing written',
        'missing': corpus.missingCells,
      }),
    );
    return;
  }

  final root = Directory(output);
  corpus.writeTo(root);
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'output': output,
      'coverage': '${output}/coverage.md',
      'captures': corpus.captures.length,
      'runtimes': [
        for (final runtime in corpus.coverage.runtimes) runtime.name,
      ],
      'tuner': [
        for (final runtime in corpus.coverage.runtimes)
          'dart run tool/pose_filter_tune.dart --captures '
              '$output/${runtime.name} --markdown '
              '$output/${runtime.name}-grid.md',
      ],
    }),
  );
}

void _fail(String message, int code) {
  stderr.writeln(jsonEncode({'error': message}));
  exitCode = code;
}
