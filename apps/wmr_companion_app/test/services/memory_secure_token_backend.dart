import 'package:wmr_companion_app/services/bridge_token_store.dart';

/// In-memory [SecureTokenBackend] for widget tests. It never touches the
/// platform channel; [values] lets a test assert what the app saved.
class MemorySecureTokenBackend implements SecureTokenBackend {
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
