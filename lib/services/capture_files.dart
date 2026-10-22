import 'dart:async';
import 'dart:io';

import 'capture_recorder.dart';

/// Appends to a file through a buffered [IOSink]; [add] only queues text.
class FileCaptureSink implements CaptureSink {
  FileCaptureSink(File file) : _sink = file.openWrite();

  final IOSink _sink;

  @override
  void add(String text) => _sink.write(text);

  @override
  Future<void> close() => _sink.close();
}

/// A saved capture.
class SavedCapture {
  const SavedCapture(this.path, this.bytes, this.modified);

  final String path;
  final int bytes;
  final DateTime modified;

  String get name => path.split(RegExp(r'[\\/]')).last;
}

/// Capture files in one directory (the app documents directory in the app).
class CaptureStore {
  CaptureStore(this.directory);

  final Directory directory;

  File newFile(int hand, DateTime now) {
    directory.createSync(recursive: true);
    final sep = Platform.pathSeparator;
    return File('${directory.path}$sep${CaptureFormat.fileName(hand, now)}');
  }

  /// Newest first.
  List<SavedCapture> list() {
    if (!directory.existsSync()) return const [];
    final out = <SavedCapture>[];
    for (final e in directory.listSync()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!RegExp(r'^(left|right)-\d{8}-\d{6}\.txt$').hasMatch(name)) continue;
      final stat = e.statSync();
      out.add(SavedCapture(e.path, stat.size, stat.modified));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }
}
