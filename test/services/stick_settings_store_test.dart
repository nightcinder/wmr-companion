import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/stick_centre.dart';
import 'package:wmr_companion/services/stick_settings_store.dart';

const custom = StickSettings(
  config: StickConfig(deadZone: 0.15, learn: false),
  centres: [
    [0.03, 0.148],
    null,
  ],
);

void main() {
  group('FileStickSettingsStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('stick_settings'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('saves and loads, and a missing file is null', () async {
      final store = FileStickSettingsStore(dir);
      expect(await store.load(), isNull);
      await store.save(custom);
      expect(await FileStickSettingsStore(dir).load(), custom);
      expect(File('${dir.path}/stick_settings.json.tmp').existsSync(), false);
    });

    test('a corrupt file is ignored', () async {
      File('${dir.path}/stick_settings.json').writeAsStringSync('{nope');
      expect(await FileStickSettingsStore(dir).load(), isNull);
    });

    test('a file with the wrong shape is ignored', () async {
      File('${dir.path}/stick_settings.json').writeAsStringSync('[]');
      expect(await FileStickSettingsStore(dir).load(), isNull);
    });

    test('a newer file version is ignored', () async {
      File('${dir.path}/stick_settings.json')
          .writeAsStringSync('{"version":2}');
      expect(await FileStickSettingsStore(dir).load(), isNull);
    });

    test('an unreadable file is ignored', () async {
      // A directory at the file path makes readAsString throw a
      // FileSystemException, which must not escape to the caller.
      Directory('${dir.path}/stick_settings.json').createSync();
      expect(await FileStickSettingsStore(dir).load(), isNull);
    });
  });

  test('NoStickSettingsStore keeps nothing', () async {
    const store = NoStickSettingsStore();
    expect(await store.load(), isNull);
    await store.save(custom);
    expect(await store.load(), isNull);
  });
}
