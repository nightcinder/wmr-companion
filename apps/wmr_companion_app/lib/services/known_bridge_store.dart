import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// The last LAN bridge the app connected to, so the next launch can find it
/// again without a tap. The token is deliberately not kept: the LAN screen
/// tells the user it is not stored, and a bridge that needs one still asks.
class KnownBridge {
  const KnownBridge({
    required this.bridgeId,
    required this.hosts,
    required this.port,
    this.bleFallback = true,
  });

  /// Stable id the bridge reports in its LAN replies and WebSocket `hello`.
  final String bridgeId;

  /// Every interface address discovery reported, primary first.
  final List<String> hosts;

  final int port;

  /// Whether the remembered link used the TCP-first BLE fallback composite.
  final bool bleFallback;
}

/// Where the last connected LAN bridge lives between app runs.
abstract class KnownBridgeStore {
  /// The saved bridge, or null when there is none or it is unreadable.
  Future<KnownBridge?> load();

  Future<void> save(KnownBridge bridge);

  Future<void> clear();
}

/// One small JSON file. The directory comes from the caller (the app's
/// documents directory) so tests can use a temp directory.
class FileKnownBridgeStore implements KnownBridgeStore {
  FileKnownBridgeStore(Directory directory)
    : _file = File('${directory.path}/known_bridge.json');

  final File _file;

  @override
  Future<KnownBridge?> load() async {
    try {
      if (!await _file.exists()) return null;
      return _decode(jsonDecode(await _file.readAsString()));
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Writes to a temporary file and renames it, so a crash mid-write leaves
  /// the previous bridge.
  @override
  Future<void> save(KnownBridge bridge) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'bridge_id': bridge.bridgeId,
        'hosts': bridge.hosts,
        'port': bridge.port,
        'ble_fallback': bridge.bleFallback,
      }),
    );
    await tmp.rename(_file.path);
  }

  @override
  Future<void> clear() async {
    try {
      await _file.delete();
    } on FileSystemException {
      // Nothing saved already.
    }
  }

  static KnownBridge? _decode(Object? decoded) {
    if (decoded is! Map) return null;
    final bridgeId = decoded['bridge_id'];
    final rawHosts = decoded['hosts'];
    final port = decoded['port'];
    final bleFallback = decoded['ble_fallback'];
    if (bridgeId is! String ||
        bridgeId.isEmpty ||
        rawHosts is! List ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      return null;
    }
    final hosts = <String>[
      for (final host in rawHosts)
        if (host is String && host.trim().isNotEmpty) host,
    ];
    if (hosts.isEmpty) return null;
    return KnownBridge(
      bridgeId: bridgeId,
      hosts: hosts,
      port: port,
      bleFallback: bleFallback is bool ? bleFallback : true,
    );
  }
}

/// Keeps nothing; used where no storage is available.
class NoKnownBridgeStore implements KnownBridgeStore {
  const NoKnownBridgeStore();

  @override
  Future<KnownBridge?> load() async => null;

  @override
  Future<void> save(KnownBridge bridge) async {}

  @override
  Future<void> clear() async {}
}

/// The app documents directory, or nowhere when it is unavailable (tests,
/// unsupported platform).
final knownBridgeStoreProvider = Provider<KnownBridgeStore>(
  (ref) => _LazyKnownBridgeStore(),
);

class _LazyKnownBridgeStore implements KnownBridgeStore {
  Future<KnownBridgeStore> _store() async {
    try {
      return FileKnownBridgeStore(await getApplicationDocumentsDirectory());
    } catch (_) {
      return const NoKnownBridgeStore();
    }
  }

  late final Future<KnownBridgeStore> _resolved = _store();

  @override
  Future<KnownBridge?> load() async => (await _resolved).load();

  @override
  Future<void> save(KnownBridge bridge) async => (await _resolved).save(bridge);

  @override
  Future<void> clear() async => (await _resolved).clear();
}
