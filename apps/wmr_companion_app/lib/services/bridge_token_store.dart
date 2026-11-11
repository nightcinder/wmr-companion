import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One key/value slot behind [BridgeTokenStore].
///
/// Production uses the platform secure storage: Android Keystore-backed
/// encrypted preferences and the iOS/macOS Keychain. Tests pass an in-memory
/// backend so no plugin channel is touched.
abstract class SecureTokenBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// [SecureTokenBackend] backed by `flutter_secure_storage`.
class PlatformSecureTokenBackend implements SecureTokenBackend {
  const PlatformSecureTokenBackend([
    this.storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// Remembers the Pi bridge bearer token across app runs.
///
/// A bridge is looked up by `bridge_id` first and by host second. The composite
/// transport learns the token from the Pi's FF13 encrypted characteristic and
/// saves it here, so a later launch can authenticate over Wi-Fi while
/// Bluetooth is off. A token typed into the Wi-Fi panel is saved only when the
/// user opts in.
///
/// The value is never logged and never written outside the platform secure
/// storage. A missing or locked keystore returns null and costs one manual
/// entry; it does not fail the connect.
class BridgeTokenStore {
  BridgeTokenStore(this._backend);

  final SecureTokenBackend _backend;

  static const _namespace = 'wmr.bridge.token.v1';

  /// The saved token for [bridgeId], else for the first matching host.
  Future<String?> load({String? bridgeId, String? host}) async {
    for (final key in _keys(bridgeId: bridgeId, hosts: [?host])) {
      final value = await _read(key);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Saves [token] under [bridgeId] and every host, so both the discovered
  /// path and a hand-typed address find it again.
  Future<void> save({
    String? bridgeId,
    Iterable<String> hosts = const <String>[],
    required String token,
  }) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return;
    for (final key in _keys(bridgeId: bridgeId, hosts: hosts)) {
      try {
        await _backend.write(key, trimmed);
      } catch (_) {
        // A locked or missing keystore must not break the live connection.
      }
    }
  }

  Future<void> clear({
    String? bridgeId,
    Iterable<String> hosts = const <String>[],
  }) async {
    for (final key in _keys(bridgeId: bridgeId, hosts: hosts)) {
      try {
        await _backend.delete(key);
      } catch (_) {
        // Nothing saved, or no storage on this platform.
      }
    }
  }

  Future<String?> _read(String key) async {
    try {
      return await _backend.read(key);
    } catch (_) {
      return null;
    }
  }

  static Iterable<String> _keys({
    String? bridgeId,
    required Iterable<String> hosts,
  }) {
    final keys = <String>{};
    final bridge = bridgeId?.trim();
    if (bridge != null && bridge.isNotEmpty) {
      keys.add('$_namespace.bridge.$bridge');
    }
    for (final host in hosts) {
      final normalised = host.trim().toLowerCase();
      if (normalised.isNotEmpty) keys.add('$_namespace.host.$normalised');
    }
    return keys;
  }
}

/// The platform secure store. Tests override this with an in-memory store.
final bridgeTokenStoreProvider = Provider<BridgeTokenStore>(
  (ref) => BridgeTokenStore(const PlatformSecureTokenBackend()),
);
