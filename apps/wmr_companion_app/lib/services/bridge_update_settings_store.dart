import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// The user's bridge update preferences between app runs.
///
/// Only the pre-release opt-in is kept: release checks use the latest stable
/// release unless the user asked for release candidates.
abstract class BridgeUpdateSettingsStore {
  /// Whether update checks include pre-release builds. False when nothing is
  /// saved or the file cannot be read.
  Future<bool> load();

  Future<void> save(bool includePreReleases);
}

/// One small JSON file. The directory comes from the caller (the app's
/// documents directory) so tests can use a temp directory.
class FileBridgeUpdateSettingsStore implements BridgeUpdateSettingsStore {
  FileBridgeUpdateSettingsStore(Directory directory)
    : _file = File('${directory.path}/bridge_update_settings.json');

  final File _file;

  /// The only key the file carries, so a future setting can be added without
  /// guessing at the document shape.
  static const String includePreReleasesKey = 'includePreReleases';

  @override
  Future<bool> load() async {
    try {
      if (!await _file.exists()) return false;
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return false;
      final includePreReleases = decoded[includePreReleasesKey];
      return includePreReleases is bool ? includePreReleases : false;
    } on FormatException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  /// Writes to a temporary file and renames it, so a crash mid-write leaves
  /// the previous setting.
  @override
  Future<void> save(bool includePreReleases) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({includePreReleasesKey: includePreReleases}),
    );
    await tmp.rename(_file.path);
  }
}

/// Keeps nothing; used where no storage is available.
class NoBridgeUpdateSettingsStore implements BridgeUpdateSettingsStore {
  const NoBridgeUpdateSettingsStore();

  @override
  Future<bool> load() async => false;

  @override
  Future<void> save(bool includePreReleases) async {}
}

/// The app documents directory, or nowhere when it is unavailable (tests,
/// unsupported platform).
final bridgeUpdateSettingsStoreProvider = Provider<BridgeUpdateSettingsStore>(
  (ref) => _LazyBridgeUpdateSettingsStore(),
);

class _LazyBridgeUpdateSettingsStore implements BridgeUpdateSettingsStore {
  Future<BridgeUpdateSettingsStore> _store() async {
    try {
      return FileBridgeUpdateSettingsStore(
        await getApplicationDocumentsDirectory(),
      );
    } catch (_) {
      return const NoBridgeUpdateSettingsStore();
    }
  }

  late final Future<BridgeUpdateSettingsStore> _resolved = _store();

  @override
  Future<bool> load() async => (await _resolved).load();

  @override
  Future<void> save(bool includePreReleases) async =>
      (await _resolved).save(includePreReleases);
}
