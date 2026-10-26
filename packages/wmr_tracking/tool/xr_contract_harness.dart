/// Host-only XR adapter contract harness.
///
/// Replays deterministic head and 26-joint hand frames through both contracts
/// the companion implements: the native plugin/event-channel JSON in OpenXR
/// axes (`wmr_tracking_android_xr`) and the Unity UaaL/sidecar JSON in
/// left-handed Unity axes (`wmr_tracking_viture`, `wmr_tracking_xreal`). It
/// also decodes paired golden fixtures and proves malformed frames are
/// rejected. No headset, Unity or Android XR runtime is involved.
///
/// ```sh
/// cd packages/wmr_tracking
/// dart run tool/xr_contract_harness.dart
/// dart run tool/xr_contract_harness.dart --json
/// ```
///
/// Exit codes: 0 pass, 1 contract failure, 2 bad arguments or unreadable
/// fixture. Passing a valid frame as `--malformed` makes the run fail, which
/// is how the rejection check itself is verified.
library;

import 'dart:convert';
import 'dart:io';

import 'package:wmr_tracking/wmr_tracking.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  try {
    final fixtures = [
      XrContractFixture(
        name: 'head frame',
        nativeJson: _read(
          options.fixtures,
          'xr_contract_native_head_frame.json',
        ),
        unityJson: _read(options.fixtures, 'xr_contract_unity_head_frame.json'),
      ),
      XrContractFixture(
        name: 'hand frame',
        nativeJson: _read(
          options.fixtures,
          'xr_contract_native_hand_frame.json',
        ),
        unityJson: _read(options.fixtures, 'xr_contract_unity_hand_frame.json'),
      ),
    ];
    final malformed = [
      for (final path in options.malformed) File(path).readAsStringSync(),
    ];

    final report = XrContractHarness(
      headRateHz: options.headRateHz,
      handRateHz: options.handRateHz,
      duration: Duration(milliseconds: options.durationMs),
    ).run(fixtures: fixtures, malformedJson: malformed);

    if (options.json) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
      );
    } else {
      _printReport(report, options);
    }
    if (!report.passes) exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln('fixture error: ${error.message}: ${error.path}');
    exitCode = 2;
  }
}

void _printReport(XrContractReport report, _Options options) {
  stdout.writeln('XR adapter contract harness (host only, no headset)');
  stdout.writeln(
    'requested: head ${options.headRateHz} Hz, hands ${options.handRateHz} Hz, '
    '${options.durationMs} ms',
  );
  for (final mode in report.modes) {
    stdout.writeln(
      '${mode.mode.label.padRight(13)} frames=${mode.frames} '
      'hand_frames=${mode.handFrames} '
      'head=${mode.head.hz.toStringAsFixed(2)} Hz '
      'hands=${mode.hands.hz.toStringAsFixed(2)} Hz '
      'joints=${mode.jointsPerHand}',
    );
  }
  stdout.writeln('golden fixtures: ${report.fixturePairs} pairs');
  stdout.writeln(
    'malformed: ${report.malformedRejected ? 'rejected' : 'ACCEPTED'} '
    '(${report.malformedChecked} checked)',
  );
  if (report.passes) {
    stdout.writeln('PASS');
    return;
  }
  stdout.writeln('FAIL');
  for (final failure in report.failures) {
    stderr.writeln(' - $failure');
  }
}

String _read(String directory, String name) =>
    File('$directory/$name').readAsStringSync();

const _usage = '''
Usage: dart run tool/xr_contract_harness.dart [options]

  --fixtures <dir>       Golden fixture directory (default: test/fixtures)
  --malformed <path>     Frame that must be rejected; repeatable. Defaults to
                         xr_contract_malformed.json and
                         xr_contract_bad_timestamp.json in --fixtures
  --head-rate <hz>       Synthetic head rate (default: 60)
  --hand-rate <hz>       Synthetic hand rate (default: 30)
  --duration-ms <ms>     Replay length (default: 1000)
  --json                 Print the report as JSON
  -h, --help             Show this help''';

class _Options {
  const _Options({
    required this.fixtures,
    required this.malformed,
    required this.headRateHz,
    required this.handRateHz,
    required this.durationMs,
    required this.json,
    required this.help,
  });

  final String fixtures;
  final List<String> malformed;
  final int headRateHz;
  final int handRateHz;
  final int durationMs;
  final bool json;
  final bool help;

  static _Options? parse(List<String> arguments) {
    var fixtures = 'test/fixtures';
    final malformed = <String>[];
    var headRateHz = 60;
    var handRateHz = 30;
    var durationMs = 1000;
    var json = false;
    var help = false;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      String? value() =>
          index + 1 < arguments.length ? arguments[++index] : null;
      switch (argument) {
        case '-h' || '--help':
          help = true;
        case '--json':
          json = true;
        case '--fixtures':
          final parsed = value();
          if (parsed == null) return null;
          fixtures = parsed;
        case '--malformed':
          final parsed = value();
          if (parsed == null) return null;
          malformed.add(parsed);
        case '--head-rate':
          final parsed = int.tryParse(value() ?? '');
          if (parsed == null || parsed <= 0) return null;
          headRateHz = parsed;
        case '--hand-rate':
          final parsed = int.tryParse(value() ?? '');
          if (parsed == null || parsed <= 0) return null;
          handRateHz = parsed;
        case '--duration-ms':
          final parsed = int.tryParse(value() ?? '');
          if (parsed == null || parsed <= 0) return null;
          durationMs = parsed;
        default:
          return null;
      }
    }
    if (headRateHz % handRateHz != 0) return null;
    if (malformed.isEmpty) {
      malformed.addAll([
        '$fixtures/xr_contract_malformed.json',
        '$fixtures/xr_contract_bad_timestamp.json',
      ]);
    }
    return _Options(
      fixtures: fixtures,
      malformed: malformed,
      headRateHz: headRateHz,
      handRateHz: handRateHz,
      durationMs: durationMs,
      json: json,
      help: help,
    );
  }
}
