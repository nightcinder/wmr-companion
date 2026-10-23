import 'dart:convert';
import 'dart:io';

import '../domain/gamepad.dart';

/// Where the gamepad settings live between app runs.
abstract class GamepadSettingsStore {
  /// The saved settings, or null if there are none or they are unreadable.
  Future<GamepadConfig?> load();

  Future<void> save(GamepadConfig config);
}

/// One small JSON file. The directory comes from the caller (the app's
/// documents directory) so tests can use a temp directory.
class FileGamepadSettingsStore implements GamepadSettingsStore {
  FileGamepadSettingsStore(Directory directory)
    : _file = File('${directory.path}/gamepad_settings.json');

  final File _file;

  @override
  Future<GamepadConfig?> load() async {
    try {
      if (!await _file.exists()) return null;
      return gamepadConfigFromJson(jsonDecode(await _file.readAsString()));
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Writes to a temporary file and renames it, so a crash mid-write leaves
  /// the previous settings.
  @override
  Future<void> save(GamepadConfig config) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(gamepadConfigToJson(config)));
    await tmp.rename(_file.path);
  }
}

/// Keeps nothing; used where no storage is available.
class NoGamepadSettingsStore implements GamepadSettingsStore {
  const NoGamepadSettingsStore();

  @override
  Future<GamepadConfig?> load() async => null;

  @override
  Future<void> save(GamepadConfig config) async {}
}
