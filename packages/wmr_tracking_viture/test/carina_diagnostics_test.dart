import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_tracking_viture/wmr_tracking_viture.dart';

Map<String, Object?> _report({bool ok = true, int code = 0, String? error}) =>
    <String, Object?>{
      'schema': 'wmr.carina.diagnostics.v1',
      'ok': ok,
      'code': code,
      'error': error,
      'width': 1920,
      'height': 1080,
      'frames': 300,
      'fps': 25.0,
      'callbackCopyLatencyUs': <String, Object?>{
        'samples': 300,
        'mean': 812.5,
        'max': 2100,
      },
      'pose': <String, Object?>{
        'polls': 1200,
        'successes': 1199,
        'rateHz': 99.9,
        'status': 0,
        'valid': true,
        'last': <double>[0.1, 0.2, 0.3, 1.0, 0.0, 0.0, 0.0],
      },
      'exposure': <String, Object?>{
        'ladderMs': carinaDiagnosticExposureLadderMs,
        'gain': carinaDiagnosticGain,
        'calls': 4,
        'failures': 0,
        'framesPerRung': <int>[75, 75, 75, 75],
      },
      'frameFilesWritten': 16,
      'frameFilesFailed': 0,
      'durationMs': 12000,
    };

void main() {
  test('the diagnostic ladder and gain are fixed by counsel', () {
    expect(carinaDiagnosticExposureLadderMs, <double>[0.1, 0.3, 1.0, 3.0]);
    expect(carinaDiagnosticGain, 6);
  });

  test('capture stays off unless the debug dart-define is set', () async {
    expect(VitureCarinaDiagnostics.enabled, isFalse);
    await expectLater(VitureCarinaDiagnostics.capture(), throwsStateError);
  });

  test('decodes the native telemetry', () {
    final report = CarinaDiagnosticReport.fromJson(_report());
    expect(report.ok, isTrue);
    expect(report.width, 1920);
    expect(report.height, 1080);
    expect(report.fps, 25.0);
    expect(report.copyMeanUs, 812.5);
    expect(report.copyMaxUs, 2100);
    expect(report.poseRateHz, 99.9);
    expect(report.poseStatus, 0);
    expect(report.poseValid, isTrue);
    expect(report.pose, hasLength(7));
    expect(report.ladderMs, carinaDiagnosticExposureLadderMs);
    expect(report.framesPerRung, <int>[75, 75, 75, 75]);
    expect(report.frameFilesWritten, 16);
  });

  test('keeps a native failure report readable', () {
    final report = CarinaDiagnosticReport.fromJson(
      _report(ok: false, code: -4, error: 'libglasses.so is not loaded'),
    );
    expect(report.ok, isFalse);
    expect(report.code, -4);
    expect(report.error, 'libglasses.so is not loaded');
  });

  test('rejects an unknown telemetry schema', () {
    final json = _report()..['schema'] = 'wmr.carina.diagnostics.v0';
    expect(
      () => CarinaDiagnosticReport.fromJson(json),
      throwsA(isA<CarinaDiagnosticException>()),
    );
  });
}
