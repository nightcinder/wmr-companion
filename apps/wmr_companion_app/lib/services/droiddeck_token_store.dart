import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bridge_token_store.dart'
    show PlatformSecureTokenBackend, SecureTokenBackend;

/// Parses pasted text into the uint32 pairing token the UDP fallback stamps
/// at offset 32. Decimal digits only, 0 to 4294967295; anything else is null.
/// An empty field is null too: no token is the default, not an error.
int? parseDroidDeckToken(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final value = int.tryParse(trimmed, radix: 10);
  if (value == null || value < 0 || value > 0xFFFFFFFF) return null;
  return value;
}

/// Remembers the optional DroidDeck UDP pairing token across app runs.
///
/// One value under one key of its own namespace, never under the bridge
/// Wi-Fi token store's. A missing or locked keystore reads as no token and
/// costs one manual entry; it does not fail the stream.
class DroidDeckTokenStore {
  DroidDeckTokenStore(this._backend);

  final SecureTokenBackend _backend;

  static const _namespace = 'wmr.droiddeck.token.v1';
  static const _key = '$_namespace.value';

  /// The saved token, or null when nothing valid is stored.
  Future<int?> load() async {
    final raw = await _read(_key);
    return raw == null ? null : parseDroidDeckToken(raw);
  }

  /// Saves [token]; a value outside uint32 is ignored, not stored.
  Future<void> save(int token) async {
    if (token < 0 || token > 0xFFFFFFFF) return;
    try {
      await _backend.write(_key, '$token');
    } catch (_) {
      // A locked or missing keystore must not break the stream.
    }
  }

  /// Removes the saved token. Opting out of remembering does not call this;
  /// only emptying the field while remembering is on does.
  Future<void> clear() async {
    try {
      await _backend.delete(_key);
    } catch (_) {
      // Nothing saved, or no storage on this platform.
    }
  }

  Future<String?> _read(String key) async {
    try {
      return await _backend.read(key);
    } catch (_) {
      return null;
    }
  }
}

/// The platform secure store. Tests override this with an in-memory store.
final droidDeckTokenStoreProvider = Provider<DroidDeckTokenStore>(
  (ref) => DroidDeckTokenStore(const PlatformSecureTokenBackend()),
);
