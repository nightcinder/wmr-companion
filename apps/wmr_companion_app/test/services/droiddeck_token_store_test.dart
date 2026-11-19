import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/bridge_token_store.dart';
import 'package:wmr_companion_app/services/droiddeck_token_store.dart';

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
  test(
    'save, reload and clear round-trip one token in the own namespace',
    () async {
      final backend = _MemoryBackend();
      final store = DroidDeckTokenStore(backend);
      expect(await store.load(), isNull);

      await store.save(12648430);
      expect(backend.values, {'wmr.droiddeck.token.v1.value': '12648430'});

      // A new instance reads what the previous app run wrote.
      final reopened = DroidDeckTokenStore(backend);
      expect(await reopened.load(), 12648430);

      await reopened.clear();
      expect(await reopened.load(), isNull);
      expect(backend.values, isEmpty);
    },
  );

  test('a value outside uint32 is never stored or read back', () async {
    final backend = _MemoryBackend();
    final store = DroidDeckTokenStore(backend);

    await store.save(0x1FFFFFFFF);
    expect(backend.values, isEmpty);

    // A corrupted stored value reads as no token, not as an error.
    backend.values['wmr.droiddeck.token.v1.value'] = 'not-a-token';
    expect(await store.load(), isNull);
  });

  test('the parser accepts decimal uint32 only', () {
    expect(parseDroidDeckToken(' 42 '), 42);
    expect(parseDroidDeckToken('0'), 0);
    expect(parseDroidDeckToken('4294967295'), 4294967295);
    expect(parseDroidDeckToken(''), isNull);
    expect(parseDroidDeckToken('-1'), isNull);
    expect(parseDroidDeckToken('4294967296'), isNull);
    expect(parseDroidDeckToken('0x2A'), isNull);
    expect(parseDroidDeckToken('12 34'), isNull);
  });

  test('a locked keystore reads as no token and never throws', () async {
    final store = DroidDeckTokenStore(_FailingBackend());
    expect(await store.load(), isNull);
    await store.save(1);
    await store.clear();
  });
}
