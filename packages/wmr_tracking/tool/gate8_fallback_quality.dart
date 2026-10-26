// Replays a synthetic nod/walk trace through the head-relative fallback and
// prints positional-error statistics with an expected-FAIL verdict. Run it
// from packages/wmr_tracking:
//
//   dart run tool/gate8_fallback_quality.dart
//
// The nod/walk trace must fail as positional tracking; the rigid head-local
// control must pass. It writes build/gate8/fallback_quality.json by default.
// Exit 0 means both expectations held, 1 means the gate did not behave as
// expected, and 2 means the harness or output could not be read or written.
// See docs/tracking/GATES.md gate 8.
import 'dart:convert';
import 'dart:io';

import 'src/gate8_fallback.dart';

const String _usage =
    'usage: dart run tool/gate8_fallback_quality.dart [--output <path>]';

void main(List<String> args) {
  var output = gate8DefaultOutputPath;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--output' && i + 1 < args.length) {
      output = args[++i];
    } else if (arg.startsWith('--output=')) {
      output = arg.substring('--output='.length);
    } else if (arg == '--help' || arg == '-h') {
      stdout.writeln(_usage);
      return;
    } else {
      _fail('unknown argument: $arg', 2);
      return;
    }
  }
  if (output.isEmpty) {
    _fail(_usage, 2);
    return;
  }

  final Gate8Result result;
  try {
    result = Gate8Result.run(outputPath: output);
  } on Gate8Exception catch (error) {
    _fail(error.message, 2);
    return;
  } on FileSystemException catch (error) {
    _fail('${error.message}: ${error.path}', 2);
    return;
  }

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.toJson()));
  exitCode = result.passed ? 0 : 1;
}

void _fail(String message, int code) {
  stderr.writeln(jsonEncode({'error': message}));
  exitCode = code;
}
