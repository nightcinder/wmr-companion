import 'dart:io';

import 'latency_recorder.dart';

/// One saved run: a CSV of every row and a JSON summary with the same stem.
class SavedLatencyRun {
  const SavedLatencyRun(this.csvPath, this.jsonPath, this.modified);

  final String csvPath;
  final String jsonPath;
  final DateTime modified;

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
    return SavedLatencyRun(csv.path, json.path, csv.statSync().modified);
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
      out.add(SavedLatencyRun(e.path, json, e.statSync().modified));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }
}
