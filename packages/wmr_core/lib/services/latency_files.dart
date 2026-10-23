import 'dart:io';

import 'latency_recorder.dart';

/// One saved run: a CSV of every row and a JSON summary with the same stem,
/// plus `<stem>-echo.csv` when the run measured a round trip.
class SavedLatencyRun {
  const SavedLatencyRun(
    this.csvPath,
    this.jsonPath,
    this.modified, {
    this.echoCsvPath,
  });

  final String csvPath;
  final String jsonPath;
  final DateTime modified;
  final String? echoCsvPath;

  /// Every file of the run.
  List<String> get paths => [csvPath, jsonPath, ?echoCsvPath];

  String get name =>
      csvPath.split(RegExp(r'[\\/]')).last.replaceAll('.csv', '');
}

/// Latency runs in one directory (`latency/` under the app documents
/// directory in the app).
class LatencyStore {
  LatencyStore(this.directory);

  final Directory directory;

  static final RegExp _csvName = RegExp(r'^latency-\d{8}-\d{6}\.csv$');

  static String stem(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'latency-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Writes both files and returns them.
  Future<SavedLatencyRun> save(
    LatencyRecorder recorder,
    LatencyReport report,
  ) async {
    await directory.create(recursive: true);
    final base =
        '${directory.path}${Platform.pathSeparator}'
        '${stem(report.started)}';
    final csv = File('$base.csv');
    final json = File('$base.json');
    await csv.writeAsString(recorder.toCsv(), flush: true);
    await json.writeAsString(report.toJsonString(), flush: true);
    File? echo;
    if (recorder.echoUsed) {
      echo = File('$base-echo.csv');
      await echo.writeAsString(recorder.toEchoCsv(), flush: true);
    }
    return SavedLatencyRun(
      csv.path,
      json.path,
      csv.statSync().modified,
      echoCsvPath: echo?.path,
    );
  }

  /// Newest first; only runs whose JSON is there too.
  List<SavedLatencyRun> list() {
    if (!directory.existsSync()) return const [];
    final out = <SavedLatencyRun>[];
    for (final e in directory.listSync()) {
      if (e is! File) continue;
      if (!_csvName.hasMatch(e.uri.pathSegments.last)) continue;
      final json = '${e.path.substring(0, e.path.length - 4)}.json';
      if (!File(json).existsSync()) continue;
      final stemPath = e.path.substring(0, e.path.length - 4);
      final echo = File('$stemPath-echo.csv');
      out.add(
        SavedLatencyRun(
          e.path,
          json,
          e.statSync().modified,
          echoCsvPath: echo.existsSync() ? echo.path : null,
        ),
      );
    }
    out.sort((a, b) {
      final byTime = b.modified.compareTo(a.modified);
      return byTime != 0 ? byTime : b.csvPath.compareTo(a.csvPath);
    });
    return out;
  }
}
