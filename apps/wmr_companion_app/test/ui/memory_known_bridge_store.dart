import 'dart:async';

import 'package:wmr_companion_app/services/known_bridge_store.dart';

class MemoryKnownBridgeStore implements KnownBridgeStore {
  MemoryKnownBridgeStore([this.saved]);

  KnownBridge? saved;
  int saves = 0;
  int clears = 0;

  /// When set, [load] waits for it, so a test can hold the launch
  /// auto-connect between reading the memory and dialling.
  Completer<void>? loadGate;

  @override
  Future<KnownBridge?> load() async {
    await loadGate?.future;
    return saved;
  }

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
