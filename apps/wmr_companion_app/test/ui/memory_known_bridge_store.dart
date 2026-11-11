import 'package:wmr_companion_app/services/known_bridge_store.dart';

class MemoryKnownBridgeStore implements KnownBridgeStore {
  MemoryKnownBridgeStore([this.saved]);

  KnownBridge? saved;
  int saves = 0;
  int clears = 0;

  @override
  Future<KnownBridge?> load() async => saved;

  @override
  Future<void> save(KnownBridge bridge) async {
    saves++;
    saved = bridge;
  }

  @override
  Future<void> clear() async {
    clears++;
    saved = null;
  }
}
