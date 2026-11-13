import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../domain/droiddeck_xr_sink.dart';

/// Thrown when a transport cannot be opened or a frame cannot be sent.
class DroidDeckXrTransportException implements Exception {
  const DroidDeckXrTransportException(this.message);

  final String message;

  @override
  String toString() => 'DroidDeckXrTransportException: $message';
}

/// Loopback UDP fallback on [DroidDeckXrProtocol.udpPort].
///
/// DroidDeck rejects a packet whose header token does not match its per-session
/// pairing token, so [token] is required and non-zero.
class DroidDeckXrUdpTransport implements DroidDeckXrTransport {
  DroidDeckXrUdpTransport({
    required this.token,
    InternetAddress? address,
    this.port = DroidDeckXrProtocol.udpPort,
  }) : address = address ?? InternetAddress.loopbackIPv4 {
    if (token == 0) {
      throw const DroidDeckXrTransportException(
        'the UDP fallback needs the host pairing token',
      );
    }
  }

  final int token;
  final InternetAddress address;
  final int port;

  RawDatagramSocket? _socket;

  Future<void> start() async {
    _socket ??= await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  }

  @override
  Future<void> send(Uint8List packet) async {
    await start();
    _socket!.send(packet, address, port);
  }

  @override
  Future<void> close() async {
    _socket?.close();
    _socket = null;
  }
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

/// Default transport: an abstract `SOCK_SEQPACKET` Unix socket.
///
/// Dart's `dart:io` sockets are `SOCK_STREAM`, so this binding calls libc
/// directly. DroidDeck authenticates the peer with `SO_PEERCRED`; the app must
/// be on the host's allowed-UID list.
class DroidDeckXrUnixTransport implements DroidDeckXrTransport {
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

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _libc.close(_fd);
  }
}

/// Opens the default abstract socket and falls back to token-paired UDP.
///
/// [udpToken] is the DroidDeck pairing token, for example read from
/// `droiddeck-ext-xr.token`. Without it the UDP fallback cannot be used, so a
/// failed socket stays a failure.
Future<DroidDeckXrTransport> openDroidDeckXrTransport({
  int? udpToken,
  String unixSocketName = DroidDeckXrProtocol.socketName,
}) async {
  try {
    return await DroidDeckXrUnixTransport.connect(name: unixSocketName);
  } on Object catch (socketError) {
    if (udpToken == null || udpToken == 0) rethrow;
    try {
      final transport = DroidDeckXrUdpTransport(token: udpToken);
      await transport.start();
      return transport;
    } on Object catch (udpError) {
      throw DroidDeckXrTransportException(
        'no transport: socket failed ($socketError), UDP failed ($udpError)',
      );
    }
  }
}

/// Reads the token DroidDeck writes next to its runtime shared-memory file.
Future<int?> readDroidDeckXrToken(Directory runtimeDir) async {
  final file = File(
    '${runtimeDir.path}${Platform.pathSeparator}'
    '${DroidDeckXrProtocol.tokenFile}',
  );
  try {
    final text = (await file.readAsString()).trim();
    return int.tryParse(text, radix: 16);
  } on FileSystemException {
    return null;
  }
}

const int _afUnix = 1;
const int _sockSeqpacket = 5;
const int _msgNoSignal = 0x4000;

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
