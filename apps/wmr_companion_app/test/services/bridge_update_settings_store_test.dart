import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/bridge_update_settings_store.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bridge-update-settings');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  File settingsFile() => File('${dir.path}/bridge_update_settings.json');

  test('defaults to stable-only when nothing is saved', () async {
    expect(await FileBridgeUpdateSettingsStore(dir).load(), isFalse);
  });

  test('round-trips the opt-in through the file', () async {
    final store = FileBridgeUpdateSettingsStore(dir);
    await store.save(true);
    expect(await FileBridgeUpdateSettingsStore(dir).load(), isTrue);

    await store.save(false);
    expect(await FileBridgeUpdateSettingsStore(dir).load(), isFalse);
  });

  test('falls back to false on a corrupt file', () async {
    await settingsFile().writeAsString('{nope');
    expect(await FileBridgeUpdateSettingsStore(dir).load(), isFalse);

    await settingsFile().writeAsString('[]');
    expect(await FileBridgeUpdateSettingsStore(dir).load(), isFalse);

    await settingsFile().writeAsString('{"includePreReleases":"yes"}');
    expect(await FileBridgeUpdateSettingsStore(dir).load(), isFalse);
  });
}
