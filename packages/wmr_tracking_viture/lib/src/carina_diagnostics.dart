import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'viture_tracking_source.dart';

/// Fixed exposure ladder for the Carina diagnostic, in milliseconds.
///
/// Counsel (ONY-731) shrank the spike to four rungs at one gain instead of a
/// full 0.01-8.0 ms x 0-15 sweep. These values stay in one place so the native
/// harness, the report and the docs cannot drift.
const List<double> carinaDiagnosticExposureLadderMs = <double>[
  0.1,
  0.3,
  1.0,
  3.0,
];

/// The single sensor gain applied to every rung.
const int carinaDiagnosticGain = 6;

/// The default per-capture duration: 3 s per rung at the SDK's 25 Hz.
const Duration carinaDiagnosticDefaultDuration = Duration(seconds: 12);

const String _libraryName = 'libcarina_diag.so';
const String _telemetryFile = 'carina-diagnostics.json';
const String _schema = 'wmr.carina.diagnostics.v1';

typedef _CaptureNative = Int32 Function(
  Int32 fileDescriptor,
  Int32 productId,
  Pointer<Utf8> outputDirectory,
  Pointer<Float> exposureLadderMs,
  Int32 ladderLength,
  Int32 gain,
  Int32 durationMs,
);
typedef _CaptureDart = int Function(
  int fileDescriptor,
  int productId,
  Pointer<Utf8> outputDirectory,
  Pointer<Float> exposureLadderMs,
  int ladderLength,
  int gain,
  int durationMs,
);

/// Debug-only trigger for the VITURE Luma Ultra Carina frame-capture spike.
///
/// Off unless the app is built with `--dart-define=WMR_VITURE_CARINA_DIAG=true`
/// *and* runs in debug mode. The capture opens the glasses over USB, blocks a
/// background isolate while the native harness walks the fixed exposure
/// ladder, then writes one PGM per rung/channel plus JSON telemetry.
///
/// The proprietary `libglasses.so` is not vendored. Stage it in the app's
/// `jniLibs/arm64-v8a/` for a local run; without it the native harness returns
/// a typed `sdkUnavailable` report instead of crashing.
abstract final class VitureCarinaDiagnostics {
  static const bool _compileTimeEnabled = bool.fromEnvironment(
    'WMR_VITURE_CARINA_DIAG',
    defaultValue: false,
  );

  /// True only in a debug build with the opt-in dart-define.
  static bool get enabled => _compileTimeEnabled && kDebugMode;

  /// Runs one capture and returns its telemetry.
  ///
  /// [outputDirectory] defaults to a new directory under `Directory.systemTemp`
  /// (the app cache directory on Android). Throws [StateError] when [enabled]
  /// is false and [CarinaDiagnosticException] when USB, the native library or
  /// the SDK is unavailable.
  static Future<CarinaDiagnosticReport> capture({
    Duration duration = carinaDiagnosticDefaultDuration,
    String? outputDirectory,
    VitureTrackingPlatform platform = const VitureTrackingPlatform(),
  }) async {
    if (!enabled) {
      throw StateError(
        'Carina diagnostics need a debug build with '
        '--dart-define=WMR_VITURE_CARINA_DIAG=true',
      );
    }
    if (!Platform.isAndroid) {
      throw const CarinaDiagnosticException(
        'unavailable',
        'Carina diagnostics require the Android VITURE USB stack',
      );
    }
    final directory = Directory(
      outputDirectory ??
          '${Directory.systemTemp.path}/wmr-carina-'
              '${DateTime.now().toUtc().toIso8601String().replaceAll(':', '')}',
    );
    await directory.create(recursive: true);

    final Map<String, Object?> usb;
    try {
      usb = await platform.openCarinaDiagnosticUsb();
    } on Object catch (error) {
      throw CarinaDiagnosticException('usbUnavailable', '$error');
    }
    final session = usb['session'];
    final fileDescriptor = usb['fd'];
    final productId = usb['productId'];
    if (session is! String || fileDescriptor is! int || productId is! int) {
      throw const CarinaDiagnosticException(
        'protocol',
        'Carina USB hand-off returned no session, fd or product id',
      );
    }

    try {
      final exitCode = await Isolate.run(
        () => _runNativeCapture(
          _NativeCaptureRequest(
            fileDescriptor: fileDescriptor,
            productId: productId,
            outputDirectory: directory.path,
            durationMs: duration.inMilliseconds,
          ),
        ),
      );
      final report = await _readReport(directory);
      if (report.ok) return report;
      throw CarinaDiagnosticException(
        _codeName(report.code),
        report.error ?? 'Carina capture failed with native code $exitCode',
      );
    } finally {
      await platform.closeCarinaDiagnosticUsb(session);
    }
  }

  static Future<CarinaDiagnosticReport> _readReport(Directory directory) async {
    final file = File('${directory.path}/$_telemetryFile');
    if (!await file.exists()) {
      throw const CarinaDiagnosticException(
        'protocol',
        'Native capture wrote no telemetry file',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException catch (error) {
      throw CarinaDiagnosticException(
        'protocol',
        'Native capture wrote malformed telemetry: ${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const CarinaDiagnosticException(
        'protocol',
        'Native capture telemetry is not a JSON object',
      );
    }
    return CarinaDiagnosticReport.fromJson(decoded);
  }

  static String _codeName(int code) => switch (code) {
    -1 => 'argument',
    -2 => 'busy',
    -3 => 'output',
    -4 => 'sdkUnavailable',
    -5 => 'sdkSymbolMissing',
    -6 => 'createFailed',
    -7 => 'initializeFailed',
    -8 => 'startFailed',
    -9 => 'callbacksFailed',
    -10 => 'noFrames',
    _ => 'captureFailed',
  };
}

int _runNativeCapture(_NativeCaptureRequest request) {
  final library = DynamicLibrary.open(_libraryName);
  final capture = library.lookupFunction<_CaptureNative, _CaptureDart>(
    'wmr_carina_diag_capture',
  );
  final outputDirectory = request.outputDirectory.toNativeUtf8();
  final ladder = calloc<Float>(carinaDiagnosticExposureLadderMs.length);
  try {
    for (var i = 0; i < carinaDiagnosticExposureLadderMs.length; i++) {
      ladder[i] = carinaDiagnosticExposureLadderMs[i];
    }
    return capture(
      request.fileDescriptor,
      request.productId,
      outputDirectory,
      ladder,
      carinaDiagnosticExposureLadderMs.length,
      carinaDiagnosticGain,
      request.durationMs,
    );
  } finally {
    calloc.free(ladder);
    malloc.free(outputDirectory);
  }
}

final class _NativeCaptureRequest {
  const _NativeCaptureRequest({
    required this.fileDescriptor,
    required this.productId,
    required this.outputDirectory,
    required this.durationMs,
  });

  final int fileDescriptor;
  final int productId;
  final String outputDirectory;
  final int durationMs;
}

/// One capture's telemetry, decoded from `carina-diagnostics.json`.
@immutable
class CarinaDiagnosticReport {
  const CarinaDiagnosticReport({
    required this.ok,
    required this.code,
    required this.error,
    required this.width,
    required this.height,
    required this.frames,
    required this.fps,
    required this.copySamples,
    required this.copyMeanUs,
    required this.copyMaxUs,
    required this.posePolls,
    required this.poseSuccesses,
    required this.poseRateHz,
    required this.poseStatus,
    required this.poseValid,
    required this.pose,
    required this.ladderMs,
    required this.gain,
    required this.framesPerRung,
    required this.frameFilesWritten,
    required this.frameFilesFailed,
    required this.durationMs,
    required this.raw,
  });

  factory CarinaDiagnosticReport.fromJson(Map<String, Object?> json) {
    if (json['schema'] != _schema) {
      throw CarinaDiagnosticException(
        'protocol',
        'Unknown Carina diagnostic schema ${json['schema']}',
      );
    }
    final copy = _map(json['callbackCopyLatencyUs']);
    final pose = _map(json['pose']);
    final exposure = _map(json['exposure']);
    return CarinaDiagnosticReport(
      ok: json['ok'] == true,
      code: _intOr(json['code'], 0),
      error: json['error'] is String ? json['error'] as String : null,
      width: _intOr(json['width'], 0),
      height: _intOr(json['height'], 0),
      frames: _intOr(json['frames'], 0),
      fps: _doubleOr(json['fps'], 0),
      copySamples: _intOr(copy['samples'], 0),
      copyMeanUs: _doubleOr(copy['mean'], 0),
      copyMaxUs: _intOr(copy['max'], 0),
      posePolls: _intOr(pose['polls'], 0),
      poseSuccesses: _intOr(pose['successes'], 0),
      poseRateHz: _doubleOr(pose['rateHz'], 0),
      poseStatus: pose['status'] is int ? pose['status'] as int : null,
      poseValid: pose['valid'] == true,
      pose: _doubles(pose['last']),
      ladderMs: _doubles(exposure['ladderMs']),
      gain: _intOr(exposure['gain'], carinaDiagnosticGain),
      framesPerRung: _ints(exposure['framesPerRung']),
      frameFilesWritten: _intOr(json['frameFilesWritten'], 0),
      frameFilesFailed: _intOr(json['frameFilesFailed'], 0),
      durationMs: _intOr(json['durationMs'], 0),
      raw: Map.unmodifiable(json),
    );
  }

  /// Whether the native harness completed a capture with frames.
  final bool ok;

  /// Native result code; 0 when [ok].
  final int code;

  /// Human-readable native failure, if any.
  final String? error;

  final int width;
  final int height;
  final int frames;

  /// Frames per second measured from the SDK's callback timestamps.
  final double fps;

  final int copySamples;
  final double copyMeanUs;
  final int copyMaxUs;

  final int posePolls;
  final int poseSuccesses;
  final double poseRateHz;

  /// `xr_device_provider_get_gl_pose_carina` status, 0 = stable.
  final int? poseStatus;
  final bool poseValid;

  /// Last `[px, py, pz, qw, qx, qy, qz]` in OpenGL coordinates.
  final List<double> pose;

  final List<double> ladderMs;
  final int gain;
  final List<int> framesPerRung;
  final int frameFilesWritten;
  final int frameFilesFailed;
  final int durationMs;

  /// The decoded telemetry, kept for fields this spike does not model yet.
  final Map<String, Object?> raw;
}

/// Typed diagnostic failure. [code] mirrors the native harness or the USB
/// hand-off (`usbUnavailable`, `permissionDenied`, `unavailable`, `protocol`).
class CarinaDiagnosticException implements Exception {
  const CarinaDiagnosticException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CarinaDiagnosticException($code): $message';
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

int _intOr(Object? value, int fallback) => value is num
    ? value.toInt()
    : value is String
    ? int.tryParse(value) ?? fallback
    : fallback;

double _doubleOr(Object? value, double fallback) => value is num
    ? value.toDouble()
    : value is String
    ? double.tryParse(value) ?? fallback
    : fallback;

List<double> _doubles(Object? value) => value is List
    ? value.map((item) => _doubleOr(item, 0)).toList(growable: false)
    : const <double>[];

List<int> _ints(Object? value) => value is List
    ? value.map((item) => _intOr(item, 0)).toList(growable: false)
    : const <int>[];
