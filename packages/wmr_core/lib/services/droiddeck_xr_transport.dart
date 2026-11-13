import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../domain/droiddeck_xr_sink.dart';
import 'droiddeck_xr_queued_transport.dart';

/// Thrown when a transport cannot be opened or a frame cannot be sent.
class DroidDeckXrTransportException implements Exception {
  const DroidDeckXrTransportException(this.message);

  final String message;

  @override
  String toString() => 'DroidDeckXrTransportException: $message';
}

typedef _SocketNative = Int32 Function(Int32, Int32, Int32);
typedef _SocketDart = int Function(int, int, int);
typedef _ConnectNative = Int32 Function(Int32, Pointer<_SockAddrUn>, Int32);
typedef _ConnectDart = int Function(int, Pointer<_SockAddrUn>, int);
typedef _SendNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int32);
typedef _SendDart = int Function(int, Pointer<Uint8>, int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

final class _SockAddrUn extends Struct {
  @Uint16()
  external int sunFamily;

  @Array(108)
  external Array<Uint8> sunPath;
}

/// Default and only transport: an abstract `SOCK_SEQPACKET` Unix socket.
///
/// Dart's `dart:io` sockets are `SOCK_STREAM`, so this binding calls libc
/// directly. DroidDeck authenticates the peer with `SO_PEERCRED` and approves
/// the companion's UID by package; the app must use
/// `com.onyxlens.wmr_companion` or `.debug` as its `applicationId`.
class DroidDeckXrUnixTransport implements DroidDeckXrNonBlockingTransport {
  DroidDeckXrUnixTransport._(this._fd, this._libc);

  final int _fd;
  final _Libc _libc;
  bool _closed = false;

  static Future<DroidDeckXrUnixTransport> connect({
    String name = DroidDeckXrProtocol.socketName,
  }) async {
    if (!Platform.isAndroid && !Platform.isLinux) {
      throw const DroidDeckXrTransportException(
        'the abstract socket transport is Android and Linux only',
      );
    }
    final libc = _Libc.open();
    final nameBytes = utf8.encode(name);
    if (nameBytes.length > 106) {
      throw const DroidDeckXrTransportException('socket name is too long');
    }
    final fd = libc.socket(_afUnix, _sockSeqpacket, 0);
    if (fd < 0) {
      throw const DroidDeckXrTransportException('cannot create SOCK_SEQPACKET');
    }
    final address = libc.malloc(sizeOf<_SockAddrUn>()).cast<_SockAddrUn>();
    try {
      address.ref.sunFamily = _afUnix;
      address.ref.sunPath[0] = 0;
      for (var i = 0; i < nameBytes.length; i++) {
        address.ref.sunPath[1 + i] = nameBytes[i];
      }
      final length = 2 + 1 + nameBytes.length;
      final result = libc.connect(fd, address, length);
      if (result != 0) {
        libc.close(fd);
        throw DroidDeckXrTransportException(
          'cannot connect to abstract socket "$name"',
        );
      }
      return DroidDeckXrUnixTransport._(fd, libc);
    } finally {
      libc.free(address.cast());
    }
  }

  @override
  Future<void> send(Uint8List packet) async {
    if (_closed) throw const DroidDeckXrTransportException('transport closed');
    final buffer = _libc.malloc(packet.length).cast<Uint8>();
    try {
      buffer.asTypedList(packet.length).setAll(0, packet);
      final sent = _libc.send(_fd, buffer, packet.length, _msgNoSignal);
      if (sent != packet.length) {
        throw const DroidDeckXrTransportException('short socket write');
      }
    } finally {
      _libc.free(buffer.cast());
    }
  }

  /// Writes one packet if the socket accepts it now. Returns false instead of
  /// waiting when the buffer is full or the write fails; errno is not read.
  @override
  bool trySend(Uint8List packet) {
    if (_closed) return false;
    final buffer = _libc.malloc(packet.length).cast<Uint8>();
    try {
      buffer.asTypedList(packet.length).setAll(0, packet);
      final sent = _libc.send(
        _fd,
        buffer,
        packet.length,
        _msgNoSignal | _msgDontWait,
      );
      return sent == packet.length;
    } finally {
      _libc.free(buffer.cast());
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _libc.close(_fd);
  }
}

/// Opens the abstract socket DroidDeck listens on.
///
/// The companion uses this path only. DroidDeck's loopback UDP fallback needs a
/// pairing token that lives in DroidDeck's private `filesDir`, which this app's
/// UID cannot read, so a failed connect is an error rather than a fallback.
/// The exception names the socket so a missing host or an unapproved
/// `applicationId` is visible in the log instead of looking like dropped
/// packets.
///
/// The returned transport never blocks the caller: packets go through a
/// [DroidDeckXrQueuedTransport] that drops the oldest packet when full and
/// reopens the socket after a sustained failure.
Future<DroidDeckXrTransport> openDroidDeckXrTransport({
  String unixSocketName = DroidDeckXrProtocol.socketName,
}) async {
  try {
    final first = await DroidDeckXrUnixTransport.connect(name: unixSocketName);
    return DroidDeckXrQueuedTransport(
      transport: first,
      reopen: () => DroidDeckXrUnixTransport.connect(name: unixSocketName),
    );
  } on Object catch (error) {
    throw DroidDeckXrTransportException(
      'cannot open DroidDeck ext-xr socket "$unixSocketName": $error. '
      'Check that DroidDeck is running and this app is installed as '
      'com.onyxlens.wmr_companion (or .debug).',
    );
  }
}

const int _afUnix = 1;
const int _sockSeqpacket = 5;
const int _msgNoSignal = 0x4000;
const int _msgDontWait = 0x40;

class _Libc {
  _Libc._(DynamicLibrary library)
    : socket = library.lookupFunction<_SocketNative, _SocketDart>('socket'),
      connect = library.lookupFunction<_ConnectNative, _ConnectDart>('connect'),
      send = library.lookupFunction<_SendNative, _SendDart>('send'),
      close = library.lookupFunction<_CloseNative, _CloseDart>('close'),
      malloc = library.lookupFunction<_MallocNative, _MallocDart>('malloc'),
      free = library.lookupFunction<_FreeNative, _FreeDart>('free');

  factory _Libc.open() {
    try {
      return _Libc._(DynamicLibrary.process());
    } on Object {
      if (Platform.isAndroid) {
        return _Libc._(DynamicLibrary.open('libc.so'));
      }
      if (Platform.isLinux) {
        return _Libc._(DynamicLibrary.open('libc.so.6'));
      }
      rethrow;
    }
  }

  final int Function(int domain, int type, int protocol) socket;
  final int Function(int fd, Pointer<_SockAddrUn> address, int length) connect;
  final int Function(int fd, Pointer<Uint8> buffer, int length, int flags) send;
  final int Function(int fd) close;
  final Pointer<Void> Function(int size) malloc;
  final void Function(Pointer<Void> pointer) free;
}
