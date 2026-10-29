import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

/// Pose recordings in one directory (the app documents directory in the app).
///
/// Files are plain versioned JSON; [list] only returns names [save] writes.
class PoseRecordingStore {
  PoseRecordingStore(this.directory);

  final Directory directory;

  static final RegExp _namePattern = RegExp(r'^pose-\d{8}-\d{6}\.json$');

  /// Writes [recording] and returns the new file.
  Future<File> save(PoseRecording recording, DateTime now) =>
      _write(recording, fileName(now));

  /// Writes one guided-bench capture with the ONY-505 file name.
  Future<File> saveCapture(
    PoseRecording recording, {
    required String runtime,
    required String hand,
    required String segment,
    required DateTime now,
  }) => _write(
    recording,
    captureFileName(runtime: runtime, hand: hand, segment: segment),
  );

  Future<File> _write(PoseRecording recording, String name) async {
    await directory.create(recursive: true);
    final separator = Platform.pathSeparator;
    final file = File('${directory.path}$separator$name');
    await file.writeAsString(recording.encode());
    return file;
  }

  /// Newest first.
  List<File> list() {
    if (!directory.existsSync()) return const [];
    final files = <File>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      if (!_namePattern.hasMatch(entity.uri.pathSegments.last)) continue;
      files.add(entity);
    }
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    return files;
  }

  /// Decodes [file], throwing [PoseRecordingException] on a malformed file.
  ///
  /// The read is synchronous: recordings are small, and this also lets widget
  /// tests drive loading without a real event-loop round trip.
  Future<PoseRecording> load(File file) async =>
      PoseRecording.decode(file.readAsStringSync());

  static String fileName(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'pose-${now.year.toString().padLeft(4, '0')}'
        '${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  static String captureFileName({
    required String runtime,
    required String hand,
    required String segment,
  }) => 'pose_capture_${runtime}_${hand}_$segment.json';
}

/// The store for this run's app documents directory.
final poseRecordingStoreProvider = FutureProvider<PoseRecordingStore>((
  ref,
) async {
  final directory = await getApplicationDocumentsDirectory();
  return PoseRecordingStore(directory);
});
