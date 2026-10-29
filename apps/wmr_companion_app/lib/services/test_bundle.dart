import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// One connected bridge, as the diagnostics and the manifest describe it.
class BundleBridge {
  const BundleBridge({
    required this.id,
    this.transport,
    this.firmwareVersion,
    this.firmwareMalformed = false,
    this.firmwareFeaturePresent = false,
    this.firmwareUnavailable = false,
    this.features = const [],
    this.mtu,
    this.rssi,
    this.connectionIntervalUs,
    this.phy,
    this.linkState,
    this.mode,
    this.rateHz = const [],
    this.loss = const [],
  });

  final String id;

  /// `BLE` or `Wi-Fi`, when the screen knows it.
  final String? transport;

  /// The FF16 string, null when the bridge did not report one.
  final String? firmwareVersion;
  final bool firmwareMalformed;

  /// Whether the GATT table offered FF16 at all.
  final bool firmwareFeaturePresent;

  /// True when service discovery failed, so no FF16 read can happen.
  final bool firmwareUnavailable;

  /// Offered FF characteristics, by enum name.
  final List<String> features;

  final int? mtu;
  final int? rssi;
  final int? connectionIntervalUs;
  final String? phy;
  final String? linkState;
  final String? mode;
  final List<double> rateHz;
  final List<double?> loss;

  Map<String, Object?> toJson() => {
    'id': id,
    if (transport != null) 'transport': transport,
    'firmware': {
      'source': 'FF16',
      'version': firmwareVersion,
      'malformed': firmwareMalformed,
      'feature_present': firmwareFeaturePresent,
      'unavailable': firmwareUnavailable,
      'features': features,
    },
    'mtu': mtu,
    'link': {
      'state': linkState,
      'rssi_dbm': rssi,
      'connection_interval_us': connectionIntervalUs,
      'phy': phy,
    },
    'stream': {
      'mode': mode,
      'rate_hz': [for (final rate in rateHz) _finite(rate)],
      'loss': [for (final value in loss) _finite(value)],
    },
  };
}

double? _finite(double? value) =>
    value != null && value.isFinite ? value : null;

/// One guided bench step, as the manifest records it.
class BenchBundleStep {
  const BenchBundleStep({
    required this.id,
    required this.status,
    this.summary,
    this.detail,
    this.data = const {},
  });

  final String id;

  /// `done`, `skipped`, `failed`, `running` or `not_run`.
  final String status;

  /// What the step produced, when it produced something.
  final String? summary;

  /// Why it failed, when it did.
  final String? detail;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'id': id,
    'status': status,
    if (summary != null) 'summary': summary,
    if (detail != null) 'detail': detail,
    if (data.isNotEmpty) 'data': data,
  };
}

/// The guided bench run that produced this bundle, in step order.
class BenchBundleRun {
  const BenchBundleRun(this.steps);

  final List<BenchBundleStep> steps;

  int get done => steps.where((s) => s.status == 'done').length;
  int get skipped => steps.where((s) => s.status == 'skipped').length;
  int get failed => steps.where((s) => s.status == 'failed').length;

  Map<String, Object?> toJson() => {
    'steps': [for (final step in steps) step.toJson()],
  };
}

/// One recorded 6DoF pose file and the labels its zip name uses.
class PoseCaptureFile {
  const PoseCaptureFile({
    required this.path,
    required this.runtime,
    required this.hand,
    required this.segment,
  });

  final String path;

  /// `androidXr`, `viture` or `xreal`.
  final String runtime;

  /// `left` or `right`.
  final String hand;

  /// [PoseSegment.id] from the guided bench.
  final String segment;
}

/// Everything one zip needs, gathered from the app's current state and disk.
class TestBundleInput {
  const TestBundleInput({
    required this.now,
    required this.appVersion,
    required this.phone,
    required this.androidVersion,
    required this.streamMode,
    this.appCommit = 'unknown',
    this.streamFault,
    this.rawStats,
    this.decodedStats,
    this.bridges = const [],
    this.latencyFiles = const [],
    this.captureFiles = const [],
    this.poseCaptures = const [],
    this.benchRun,
  });

  /// Local time; the file name uses its date and the manifest its timestamp.
  final DateTime now;

  /// `0.2.2+4` from the package metadata.
  final String appVersion;

  /// Short git commit the APK was built from, or `unknown`.
  final String appCommit;

  /// Manufacturer and model, or the platform's own description.
  final String phone;

  /// `Android 14 (API 34)`.
  final String androidVersion;

  final String streamMode;
  final String? streamFault;

  /// Per-hand raw counters, when the service has them.
  final Map<String, Object?>? rawStats;

  /// Per-hand decoded counters, when the service has them.
  final Map<String, Object?>? decodedStats;

  final List<BundleBridge> bridges;

  /// Files of the latest saved latency run (JSON, CSV, echo CSV).
  final List<String> latencyFiles;

  /// Every saved FF11 capture.
  final List<String> captureFiles;

  /// 6DoF pose recordings from the guided bench.
  final List<PoseCaptureFile> poseCaptures;

  /// The guided bench run, null when the tester exported without one.
  final BenchBundleRun? benchRun;
}

/// What one export produced, for the screen and for tests.
class TestBundle {
  const TestBundle({
    required this.path,
    required this.fileName,
    required this.present,
    required this.missing,
  });

  final String path;
  final String fileName;

  /// Human-readable entries that made it into the zip.
  final List<String> present;

  /// Human-readable entries that did not, with the reason.
  final List<String> missing;
}

/// Writes `wmr-ext-<yyyyMMdd>.zip` into [directory].
///
/// The manifest and the README are always written. Diagnostics, the latest
/// latency run and the captures are added when they exist; [TestBundle.missing]
/// and the README name every artifact that did not.
Future<TestBundle> writeTestBundle(
  TestBundleInput input,
  Directory directory,
) async {
  await directory.create(recursive: true);
  final fileName = 'wmr-ext-${_date(input.now)}.zip';
  final path = '${directory.path}${Platform.pathSeparator}$fileName';

  final present = <String>[
    '`manifest.md` — date, phone, Android version, firmware, MTU',
    '`diagnostics.json` — app, FF16 firmware, MTU, stream and link stats',
  ];
  final missing = <String>[];
  final files = <String, List<int>>{};

  for (final source in input.latencyFiles) {
    final name = 'latency/${_baseName(source)}';
    final bytes = await _read(source);
    if (bytes == null) {
      missing.add('Latest latency file `$name` — the saved file was missing.');
      continue;
    }
    files[name] = bytes;
  }
  final latencyNames = [
    for (final source in input.latencyFiles)
      if (files.containsKey('latency/${_baseName(source)}'))
        'latency/${_baseName(source)}',
  ];
  if (latencyNames.isEmpty) {
    missing.add(
      'Latest latency run — none saved. Run the latency test, then export '
      'again.',
    );
  } else {
    present.add('Latest latency run: ${latencyNames.join(', ')}');
  }

  final captureNames = <String>[];
  for (final source in input.captureFiles) {
    final name = 'captures/${_baseName(source)}';
    final bytes = await _read(source);
    if (bytes == null) {
      missing.add('FF11 capture `$name` — the saved file was missing.');
      continue;
    }
    files[name] = bytes;
    captureNames.add(name);
  }
  if (captureNames.isEmpty) {
    missing.add(
      'FF11 captures — none saved. Record one on the Capture screen, then '
      'export again.',
    );
  } else {
    present.add(
      'FF11 captures: ${captureNames.length} file(s) '
      '(${captureNames.join(', ')})',
    );
  }

  final poseNames = <String>[];
  for (final pose in input.poseCaptures) {
    final name = poseCaptureName(pose);
    final bytes = await _read(pose.path);
    if (bytes == null) {
      missing.add('6DoF pose capture `$name` — the saved file was missing.');
      continue;
    }
    files[name] = bytes;
    poseNames.add(name);
  }
  if (poseNames.isNotEmpty) {
    present.add(
      '6DoF pose captures: ${poseNames.length} file(s) '
      '(${poseNames.join(', ')})',
    );
  }

  final firmware = _firmwareSummary(input.bridges);
  if (firmware == null) {
    missing.add('Firmware version (FF16) — ${_firmwareReason(input.bridges)}');
  } else {
    present.add('Firmware version (FF16): $firmware');
  }

  final mtu = _mtuSummary(input.bridges);
  if (mtu == null) {
    missing.add('MTU — the link did not report one.');
  } else {
    present.add('MTU: $mtu');
  }

  final bench = input.benchRun;
  if (bench != null) {
    present.add(
      'Guided bench run: ${bench.done} done, ${bench.skipped} skipped, '
      '${bench.failed} failed (${bench.steps.length} steps)',
    );
  }

  final manifest = _manifest(input);
  final readme = _readme(input, present: present, missing: missing);
  final diagnostics = const JsonEncoder.withIndent('  ').convert({
    'format': 'wmr-test-bundle/1',
    'generated_at': input.now.toUtc().toIso8601String(),
    'app': {
      'name': 'wmr_companion_app',
      'version': input.appVersion,
      'commit': input.appCommit,
    },
    'device': {'phone': input.phone, 'android': input.androidVersion},
    'stream': {
      'mode': input.streamMode,
      if (input.streamFault != null) 'fault': input.streamFault,
      if (input.rawStats != null) 'raw': input.rawStats,
      if (input.decodedStats != null) 'decoded': input.decodedStats,
    },
    'bridges': [for (final bridge in input.bridges) bridge.toJson()],
    if (bench != null) 'bench': bench.toJson(),
  });

  final archive = Archive();
  void addText(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addText('manifest.md', manifest);
  addText('README.md', '$readme\n');
  addText('diagnostics.json', '$diagnostics\n');
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }

  await File(path).writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
  return TestBundle(
    path: path,
    fileName: fileName,
    present: present,
    missing: missing,
  );
}

Future<List<int>?> _read(String path) async {
  try {
    return await File(path).readAsBytes();
  } on FileSystemException {
    return null;
  }
}

String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

/// The archive name the task fixes for one pose capture.
String poseCaptureName(PoseCaptureFile pose) =>
    'pose_capture_${pose.runtime}_${pose.hand}_${pose.segment}.json';

String _two(int value) => value.toString().padLeft(2, '0');

String _date(DateTime now) => '${now.year}${_two(now.month)}${_two(now.day)}';

String? _firmwareSummary(List<BundleBridge> bridges) {
  final values = <String>[];
  for (final bridge in bridges) {
    final value = _firmwareValue(bridge);
    if (value == null) continue;
    values.add(bridges.length == 1 ? value : '${bridge.id}: $value');
  }
  return values.isEmpty ? null : values.join('; ');
}

String? _firmwareValue(BundleBridge bridge) {
  if (bridge.firmwareMalformed) return 'malformed (FF16 present)';
  if (bridge.firmwareVersion != null) return bridge.firmwareVersion;
  return null;
}

String _firmwareReason(List<BundleBridge> bridges) {
  if (bridges.isEmpty) return 'not connected, so no FF16 read happened.';
  if (bridges.any((b) => b.firmwareMalformed)) {
    return 'the FF16 value was present but did not decode.';
  }
  if (bridges.any((b) => b.firmwareFeaturePresent)) {
    return 'the bridge did not return a usable FF16 value.';
  }
  if (bridges.any((b) => b.firmwareUnavailable)) {
    return 'the FF16 read was unavailable (service discovery failed).';
  }
  return 'FF16 had not been read yet (older firmware or a pending read).';
}

String? _mtuSummary(List<BundleBridge> bridges) {
  final values = <String>[];
  for (final bridge in bridges) {
    if (bridge.mtu == null) continue;
    values.add(
      bridges.length == 1 ? '${bridge.mtu}' : '${bridge.id}: ${bridge.mtu}',
    );
  }
  return values.isEmpty ? null : values.join('; ');
}

String _manifest(TestBundleInput input) {
  final buffer = StringBuffer()
    ..writeln('# WMR external test bundle')
    ..writeln()
    ..writeln('- Date: ${input.now.toIso8601String()}')
    ..writeln('- Phone: ${input.phone}')
    ..writeln('- Android: ${input.androidVersion}')
    ..writeln(
      '- Firmware: ${_firmwareSummary(input.bridges) ?? _firmwareReason(input.bridges)}',
    )
    ..writeln('- MTU: ${_mtuSummary(input.bridges) ?? 'not reported'}')
    ..writeln('- App: WMR Companion ${input.appVersion}')
    ..writeln('- App commit: ${input.appCommit}')
    ..writeln('- Bridges: ${input.bridges.length}')
    ..writeln();
  final bench = input.benchRun;
  if (bench != null) {
    buffer
      ..writeln('## Guided bench run')
      ..writeln();
    for (final step in bench.steps) {
      final note = step.detail ?? step.summary;
      buffer.writeln(
        '- ${step.id}: ${step.status}'
        '${note == null ? '' : ' — $note'}',
      );
    }
    buffer.writeln();
  }
  final poseSegments = _poseSegments(bench);
  if (poseSegments.isNotEmpty) {
    final first = poseSegments.first;
    buffer
      ..writeln('## 6DoF pose captures')
      ..writeln()
      ..writeln('- Runtime: ${first['runtime'] ?? 'unknown'}')
      ..writeln('- App commit: ${first['app_commit'] ?? input.appCommit}')
      ..writeln('- Firmware SHA: ${first['firmware_sha'] ?? 'unknown'}')
      ..writeln()
      ..writeln('| File | Hand | Segment | Status | Samples | Reason |')
      ..writeln('|---|---|---|---|---:|---|');
    for (final segment in poseSegments) {
      final file = segment['file'] as String?;
      buffer.writeln(
        '| ${file == null ? '—' : _baseName(file)} '
        '| ${segment['hand'] ?? '—'} '
        '| ${segment['segment'] ?? '—'} '
        '| ${segment['status'] ?? '—'} '
        '| ${segment['samples'] ?? '—'} '
        '| ${segment['reason'] ?? '—'} |',
      );
    }
    buffer.writeln();
  }
  buffer.writeln(
    'Generated by the Export test bundle or Run guided bench action on '
    'the Connect screen.',
  );
  return buffer.toString();
}

/// Segment rows from a pose step, or an empty list when the run had none.
List<Map<String, Object?>> _poseSegments(BenchBundleRun? bench) {
  if (bench == null) return const [];
  for (final step in bench.steps) {
    if (step.id != 'pose_capture') continue;
    final segments = step.data['segments'];
    if (segments is! List) return const [];
    return [
      for (final segment in segments)
        if (segment is Map)
          {for (final entry in segment.entries) '${entry.key}': entry.value},
    ];
  }
  return const [];
}

String _readme(
  TestBundleInput input, {
  required List<String> present,
  required List<String> missing,
}) {
  final buffer = StringBuffer()
    ..writeln('# WMR external test bundle')
    ..writeln()
    ..writeln(
      'Generated ${input.now.toIso8601String()} by WMR Companion '
      '${input.appVersion} on ${input.phone} (${input.androidVersion}).',
    )
    ..writeln()
    ..writeln('## Present')
    ..writeln();
  for (final item in present) {
    buffer.writeln('- $item');
  }
  buffer
    ..writeln()
    ..writeln('## Missing')
    ..writeln();
  if (missing.isEmpty) {
    buffer.writeln('- (none)');
  } else {
    for (final item in missing) {
      buffer.writeln('- $item');
    }
  }
  return buffer.toString();
}
