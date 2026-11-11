import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/known_bridge_store.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('known-bridge');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('round-trips the last connected bridge through the file', () async {
    final store = FileKnownBridgeStore(dir);
    expect(await store.load(), isNull);

    await store.save(
      const KnownBridge(
        bridgeId: 'bridge-1',
        hosts: ['192.168.1.42', '192.168.1.43'],
        port: 8765,
        bleFallback: false,
      ),
    );

    final loaded = await FileKnownBridgeStore(dir).load();
    expect(loaded?.bridgeId, 'bridge-1');
    expect(loaded?.hosts, ['192.168.1.42', '192.168.1.43']);
    expect(loaded?.port, 8765);
    expect(loaded?.bleFallback, isFalse);

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('ignores a malformed file instead of failing the launch scan', () async {
    await File('${dir.path}/known_bridge.json').writeAsString('{nope');
    expect(await FileKnownBridgeStore(dir).load(), isNull);

    await File('${dir.path}/known_bridge.json')
        .writeAsString('{"bridge_id":"","hosts":[],"port":0}');
    expect(await FileKnownBridgeStore(dir).load(), isNull);
  });
}
