// Replays a gate 7 clock-test fixture through SourceClockAligner without
// hardware and prints JSON statistics. Run it from packages/wmr_tracking:
//
//   dart run tool/gate7_clock_replay.dart --fixture <path>
//
// Exit 0 means the fixture passed, 1 means it failed the gate, and 2 means the
// fixture or capture could not be read. See docs/tracking/GATES.md gate 7.
import 'dart:convert';
import 'dart:io';

import 'src/gate7_replay.dart';

const String _usage =
    'usage: dart run tool/gate7_clock_replay.dart --fixture <path>';

void main(List<String> args) {
  String? fixture;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--fixture' && i + 1 < args.length) {
      fixture = args[++i];
    } else if (arg.startsWith('--fixture=')) {
      fixture = arg.substring('--fixture='.length);
    } else if (arg == '--help' || arg == '-h') {
      stdout.writeln(_usage);
      return;
    } else {
      _fail('unknown argument: $arg', 2);
      return;
    }
  }
  if (fixture == null || fixture.isEmpty) {
    _fail(_usage, 2);
    return;
  }

  final Gate7Result result;
  try {
    result = Gate7Result.run(fixture);
  } on Gate7Exception catch (error) {
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
