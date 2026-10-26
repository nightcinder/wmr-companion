import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/gate8_fallback.dart';

void main() {
  late Directory tempDir;
  late String outputPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('gate8_fallback_');
    outputPath = '${tempDir.path}/fallback_quality.json';
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('nod/walk fails as positional tracking', () {
    final result = Gate8Result.run(outputPath: outputPath);
    final fallback = result.fallback;

    expect(fallback.verdict, 'EXPECTED-FAIL');
    expect(fallback.passed, isTrue);
    expect(fallback.stats.samples, greaterThan(100));
    expect(fallback.stats.rmseM, greaterThan(gate8FallbackMinRmseM));
    expect(fallback.stats.maxErrorM, greaterThan(gate8FallbackMinMaxErrorM));
    expect(fallback.stats.finalErrorM, greaterThan(0));
  });

  test('rigid head-local control stays near zero', () {
    final result = Gate8Result.run(outputPath: outputPath);
    final control = result.control;

    expect(control.verdict, 'PASS');
    expect(control.passed, isTrue);
    expect(control.stats.samples, greaterThan(100));
    expect(control.stats.rmseM, lessThan(gate8ControlMaxRmseM));
    expect(control.stats.maxErrorM, lessThan(gate8ControlMaxErrorM));
  });

  test('the command exits 0 and writes JSON evidence', () async {
    final process = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/gate8_fallback_quality.dart',
      '--output',
      outputPath,
    ], workingDirectory: Directory.current.path);

    expect(process.exitCode, 0, reason: process.stderr as String?);
    final stdoutJson =
        jsonDecode(process.stdout as String) as Map<String, Object?>;
    expect(stdoutJson['verdict'], 'PASS');
    expect(stdoutJson['fallback_verdict'], 'EXPECTED-FAIL');
    expect(stdoutJson['control_verdict'], 'PASS');

    final written =
        jsonDecode(File(outputPath).readAsStringSync()) as Map<String, Object?>;
    expect(written['format'], gate8Format);
    expect(written['fallback_verdict'], 'EXPECTED-FAIL');
    expect(written['control_verdict'], 'PASS');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
