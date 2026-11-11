import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/bridge_token_store.dart';

class _MemoryBackend implements SecureTokenBackend {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _FailingBackend implements SecureTokenBackend {
  @override
  Future<String?> read(String key) async => throw StateError('locked');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('locked');

  @override
  Future<void> delete(String key) async => throw StateError('locked');
}

void main() {
  test('round-trips a token by bridge id and by host', () async {
    final backend = _MemoryBackend();
    final store = BridgeTokenStore(backend);
    expect(await store.load(bridgeId: 'pi-1', host: '172.21.1.28'), isNull);

    await store.save(
      bridgeId: 'pi-1',
      hosts: ['172.21.1.28'],
      token: ' shared-secret ',
    );

    // A new instance reads what the previous app run wrote.
    final reopened = BridgeTokenStore(backend);
    expect(await reopened.load(bridgeId: 'pi-1'), 'shared-secret');
    expect(await reopened.load(host: '172.21.1.28'), 'shared-secret');
    expect(await reopened.load(host: ' 172.21.1.28 '), 'shared-secret');
    expect(await reopened.load(bridgeId: 'pi-2'), isNull);

    await reopened.clear(bridgeId: 'pi-1', hosts: ['172.21.1.28']);
    expect(await reopened.load(bridgeId: 'pi-1'), isNull);
    expect(await reopened.load(host: '172.21.1.28'), isNull);
  });

  test('an empty token is not stored', () async {
    final backend = _MemoryBackend();
    final store = BridgeTokenStore(backend);

    await store.save(bridgeId: 'pi-1', hosts: ['pi.local'], token: '   ');

    expect(backend.values, isEmpty);
    expect(await store.load(bridgeId: 'pi-1'), isNull);
  });

  test('a missing or locked keystore reads null and never throws', () async {
    final store = BridgeTokenStore(_FailingBackend());

    expect(await store.load(bridgeId: 'pi-1', host: 'pi.local'), isNull);
    await store.save(bridgeId: 'pi-1', hosts: ['pi.local'], token: 'secret');
    await store.clear(bridgeId: 'pi-1', hosts: ['pi.local']);
  });
}
