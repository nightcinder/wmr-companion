import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/gate7_replay.dart';

const String _fixtureDir = 'tool/fixtures/gate7';

Gate7Result _run(String name) => Gate7Result.run('$_fixtureDir/$name.json');

void main() {
  test('stable-offset fixture passes the gate', () {
    final result = _run('stable_offset');

    expect(result.passed, isTrue);
    expect(result.reasons, isEmpty);
    expect(result.stats.evaluatedFrames, 1800);
    expect(result.stats.offsetStdNs, lessThan(gate7MaxOffsetStdNs));
    expect(result.stats.maxFrameAgeNs, lessThan(gate7FrameWindowNs));
    expect(result.stats.staleFrames, 0);
  });

  test('drift fixture fails with offset_drift', () {
    final result = _run('drift');

    expect(result.passed, isFalse);
    expect(result.reasons, ['offset_drift']);
    expect(result.stats.offsetStdNs, greaterThan(gate7MaxOffsetStdNs));
    expect(result.stats.maxFrameAgeNs, lessThan(gate7FrameWindowNs));
  });

  test('gap fixture fails with controller_gap', () {
    final result = _run('gap');

    expect(result.passed, isFalse);
    expect(result.reasons, ['controller_gap']);
    expect(result.stats.capture.maxGapNs, greaterThan(gate7MaxControllerGapNs));
    expect(result.stats.offsetStdNs, lessThan(gate7MaxOffsetStdNs));
  });

  test('out-of-window fixture fails with frame_out_of_window', () {
    final result = _run('out_of_window');

    expect(result.passed, isFalse);
    expect(result.reasons, ['frame_out_of_window']);
    expect(result.stats.offsetStdNs, lessThan(gate7MaxOffsetStdNs));
    expect(result.stats.staleFraction, greaterThan(gate7MaxStaleFraction));
    expect(result.stats.rejectedCorrections, greaterThan(0));
  });

  test(
    'the command exits 0 for the good fixture and 1 for each bad one',
    () async {
      const expected = {
        'stable_offset': 0,
        'drift': 1,
        'gap': 1,
        'out_of_window': 1,
      };
      for (final MapEntry(key: name, value: code) in expected.entries) {
        final process = await Process.run(Platform.resolvedExecutable, [
          'run',
          'tool/gate7_clock_replay.dart',
          '--fixture',
          '$_fixtureDir/$name.json',
        ], workingDirectory: Directory.current.path);
        final output =
            jsonDecode(process.stdout as String) as Map<String, Object?>;
        expect(process.exitCode, code, reason: '$name: ${process.stderr}');
        expect(output['verdict'], code == 0 ? 'pass' : 'fail', reason: name);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
