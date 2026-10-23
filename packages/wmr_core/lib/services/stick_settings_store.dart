import 'dart:convert';
import 'dart:io';

import '../domain/stick_centre.dart';

/// Where the stick settings and rest centres live between app runs.
abstract class StickSettingsStore {
  /// The saved settings, or null if there are none or they are unreadable.
  Future<StickSettings?> load();

  Future<void> save(StickSettings settings);
}

/// One small JSON file. The directory comes from the caller (the app's
/// documents directory) so tests can use a temp directory.
class FileStickSettingsStore implements StickSettingsStore {
  FileStickSettingsStore(Directory directory)
    : _file = File('${directory.path}/stick_settings.json');

  final File _file;

  @override
  Future<StickSettings?> load() async {
    try {
      if (!await _file.exists()) return null;
      return stickSettingsFromJson(jsonDecode(await _file.readAsString()));
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Writes to a temporary file and renames it, so a crash mid-write leaves
  /// the previous settings.
  @override
  Future<void> save(StickSettings settings) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(stickSettingsToJson(settings)));
    await tmp.rename(_file.path);
  }
}

/// Keeps nothing; used where no storage is available.
class NoStickSettingsStore implements StickSettingsStore {
  const NoStickSettingsStore();

  @override
  Future<StickSettings?> load() async => null;

  @override
  Future<void> save(StickSettings settings) async {}
}
