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

/// Read-only packet counters kept by a transport.
///
/// A packet is [accepted] once the socket takes it, [dropped] when the queue
/// was full, and [queued] while it waits for the socket. Counts are since the
/// transport opened.
class DroidDeckXrPacketStats {
  const DroidDeckXrPacketStats({
    this.accepted = 0,
    this.dropped = 0,
    this.queued = 0,
  });

  final int accepted;
  final int dropped;
  final int queued;
}

/// A transport that exposes its packet counters. The counters are owned by
/// the transport; readers get a snapshot and never reset them.
abstract interface class DroidDeckXrPacketStatsSource {
  DroidDeckXrPacketStats get packetStats;
}

typedef _SocketNative = Int32 Function(Int32, Int32, Int32);
typedef _SocketDart = int Function(int, int, int);
typedef _ConnectNative = Int32 Function(Int32, Pointer<_SockAddrUn>, Int32);
typedef _ConnectDart = int Function(int, Pointer<_SockAddrUn>, int);
typedef _ConnectInetNative = Int32 Function(Int32, Pointer<_SockAddrIn>, Int32);
typedef _ConnectInetDart = int Function(int, Pointer<_SockAddrIn>, int);
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

final class _SockAddrIn extends Struct {
  @Uint16()
  external int sinFamily;

  @Uint16()
  external int sinPort;

  @Uint32()
  external int sinAddr;

  @Array(8)
  external Array<Uint8> sinZero;
}

/// Loopback UDP fallback on `127.0.0.1:29842`.
///
/// The socket is connected to that address so the kernel reports a missing
/// listener as a failed send instead of dropping datagrams silently. Every
/// packet is stamped with [token] at [DroidDeckXrProtocol.tokenOffset] after
/// the caller encodes it, so input and claim packets are treated alike and the
/// shared encoder keeps writing zero on the socket path.
class DroidDeckXrUdpTransport implements DroidDeckXrNonBlockingTransport {
  DroidDeckXrUdpTransport._(this._fd, this._libc, this.token);

  final int _fd;
  final _Libc _libc;
  final int token;
  bool _closed = false;

  /// Opens a connected UDP socket to DroidDeck's loopback fallback.
  ///
  /// [port] is injectable so tests can bind an ephemeral receiver; production
  /// callers keep [DroidDeckXrProtocol.udpPort].
  static Future<DroidDeckXrUdpTransport> connect({
    required int token,
    int port = DroidDeckXrProtocol.udpPort,
  }) async {
    if (!Platform.isAndroid && !Platform.isLinux) {
      throw const DroidDeckXrTransportException(
        'the UDP fallback is Android and Linux only',
      );
    }
    final libc = _Libc.open();
    final fd = libc.socket(_afInet, _sockDgram, 0);
    if (fd < 0) {
      throw const DroidDeckXrTransportException('cannot create SOCK_DGRAM');
    }
    final address = libc.malloc(sizeOf<_SockAddrIn>()).cast<_SockAddrIn>();
    try {
      address.ref
        ..sinFamily = _afInet
        ..sinPort = _networkUint16(port)
        ..sinAddr = _networkUint32(const [127, 0, 0, 1]);
      for (var i = 0; i < 8; i++) {
        address.ref.sinZero[i] = 0;
      }
      final result = libc.connectInet(fd, address, sizeOf<_SockAddrIn>());
      if (result != 0) {
        libc.close(fd);
        throw DroidDeckXrTransportException(
          'cannot connect to DroidDeck UDP 127.0.0.1:$port',
        );
      }
      return DroidDeckXrUdpTransport._(fd, libc, token);
    } finally {
      libc.free(address.cast());
    }
  }

  /// Copies [packet] and writes the token, leaving the caller's buffer alone.
  Uint8List _stamped(Uint8List packet) {
    if (packet.length < DroidDeckXrProtocol.tokenOffset + 4) {
      throw const DroidDeckXrTransportException(
        'packet is too short for the DroidDeck pairing token',
      );
    }
    final out = Uint8List.fromList(packet);
    ByteData.sublistView(out)
        .setUint32(DroidDeckXrProtocol.tokenOffset, token, Endian.little);
    return out;
  }

  @override
  Future<void> send(Uint8List packet) async {
    if (_closed) throw const DroidDeckXrTransportException('transport closed');
    final stamped = _stamped(packet);
    final buffer = _libc.malloc(stamped.length).cast<Uint8>();
    try {
      buffer.asTypedList(stamped.length).setAll(0, stamped);
      final sent = _libc.send(_fd, buffer, stamped.length, _msgNoSignal);
      if (sent != stamped.length) {
        throw const DroidDeckXrTransportException(
          'DroidDeck UDP pairing failed: the datagram was not accepted. '
          'Check that DroidDeck is listening on 127.0.0.1:29842 and that the '
          'token at offset 32 matches (docs/GAMEPAD.md:128).',
        );
      }
    } finally {
      _libc.free(buffer.cast());
    }
  }

  /// Writes one stamped datagram if the socket accepts it now. A missing
  /// listener or a full buffer returns false; the queued transport owns retry.
  @override
  bool trySend(Uint8List packet) {
    if (_closed) return false;
    final Uint8List stamped;
    try {
      stamped = _stamped(packet);
    } on DroidDeckXrTransportException {
      return false;
    }
    final buffer = _libc.malloc(stamped.length).cast<Uint8>();
    try {
      buffer.asTypedList(stamped.length).setAll(0, stamped);
      final sent = _libc.send(
        _fd,
        buffer,
        stamped.length,
        _msgNoSignal | _msgDontWait,
      );
      return sent == stamped.length;
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

/// Primary transport: an abstract `SOCK_SEQPACKET` Unix socket.
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

/// Opens the abstract socket DroidDeck listens on, falling back to loopback UDP
/// when a pairing token is supplied.
///
/// The abstract socket always wins when it opens, even with a token. On a
/// failed connect the loopback UDP fallback is tried only when [token] is
/// non-null; the UDP transport stamps that token into every datagram. Without
/// a token the exception names the socket, the UDP fallback and why it was not
/// tried, so a missing host or an unapproved `applicationId` stays visible.
///
/// [connectUnix] and [connectUdp] are seams for tests. The real fallback keeps
/// the same kind and token when the queued transport reopens.
///
/// The returned transport never blocks the caller: packets go through a
/// [DroidDeckXrQueuedTransport] that drops the oldest packet when full and
/// reopens the socket after a sustained failure.
Future<DroidDeckXrTransport> openDroidDeckXrTransport({
  String unixSocketName = DroidDeckXrProtocol.socketName,
  int? token,
  DroidDeckXrUnixConnect? connectUnix,
  DroidDeckXrUdpConnect? connectUdp,
}) async {
  Future<DroidDeckXrNonBlockingTransport> openUnix() =>
      (connectUnix ??
      () => DroidDeckXrUnixTransport.connect(name: unixSocketName))();

  Future<DroidDeckXrNonBlockingTransport> openUdp(int value) =>
      (connectUdp ?? (value) => DroidDeckXrUdpTransport.connect(token: value))(
        value,
      );

  try {
    final first = await openUnix();
    return DroidDeckXrQueuedTransport(transport: first, reopen: openUnix);
  } on Object catch (socketError) {
    if (token == null) {
      throw DroidDeckXrTransportException(
        'cannot open DroidDeck ext-xr socket "$unixSocketName": $socketError. '
        'Check that DroidDeck is running and this app is installed as '
        'com.onyxlens.wmr_companion (or .debug). The loopback UDP fallback on '
        '127.0.0.1:${DroidDeckXrProtocol.udpPort} was not tried because no '
        'pairing token is set.',
      );
    }
    try {
      final first = await openUdp(token);
      return DroidDeckXrQueuedTransport(
        transport: first,
        reopen: () => openUdp(token),
      );
    } on Object catch (udpError) {
      throw DroidDeckXrTransportException(
        'cannot open DroidDeck ext-xr: abstract socket "$unixSocketName" '
        'failed ($socketError); loopback UDP fallback on 127.0.0.1:'
        '${DroidDeckXrProtocol.udpPort} failed ($udpError).',
      );
    }
  }
}

/// Opens the abstract socket transport. A test seam for the factory.
typedef DroidDeckXrUnixConnect =
    Future<DroidDeckXrNonBlockingTransport> Function();

/// Opens the loopback UDP transport for a pairing token. A test seam.
typedef DroidDeckXrUdpConnect =
    Future<DroidDeckXrNonBlockingTransport> Function(int token);

const int _afUnix = 1;
const int _afInet = 2;
const int _sockSeqpacket = 5;
const int _sockDgram = 2;
const int _msgNoSignal = 0x4000;
const int _msgDontWait = 0x40;

int _networkUint16(int value) {
  final bytes = ByteData(2)..setUint16(0, value, Endian.big);
  return bytes.getUint16(0, Endian.host);
}

int _networkUint32(List<int> raw) {
  final bytes = ByteData(4);
  for (var i = 0; i < 4; i++) {
    bytes.setUint8(i, raw[i]);
  }
  return bytes.getUint32(0, Endian.host);
}

class _Libc {
  _Libc._(DynamicLibrary library)
    : socket = library.lookupFunction<_SocketNative, _SocketDart>('socket'),
      connect = library.lookupFunction<_ConnectNative, _ConnectDart>('connect'),
      connectInet = library
          .lookupFunction<_ConnectInetNative, _ConnectInetDart>('connect'),
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
  final int Function(int fd, Pointer<_SockAddrIn> address, int length)
  connectInet;
  final int Function(int fd, Pointer<Uint8> buffer, int length, int flags) send;
  final int Function(int fd) close;
  final Pointer<Void> Function(int size) malloc;
  final void Function(Pointer<Void> pointer) free;
}
