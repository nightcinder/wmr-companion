import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'fake_pi_server.dart';

/// A loopback stand-in for the Pi UDP discovery responder.
class _UdpResponder {
  _UdpResponder._(this.socket);

  final RawDatagramSocket socket;
  String? lastProbe;

  int get port => socket.port;

  static Future<_UdpResponder> start({
    String bridgeId = 'pi-udp',
    String name = 'Kitchen Pi',
    int metadataPort = 9321,
    String Function(String nonce)? nonceOverride,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final responder = _UdpResponder._(socket);
    socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final probe = utf8.decode(datagram.data);
      responder.lastProbe = probe;
      final parts = probe.split(' ');
      if (parts.length != 2 || parts.first != wmrWsDiscoveryProbe) return;
      final nonce = parts.last;
      final reply = <String, Object?>{
        'nonce': nonceOverride?.call(nonce) ?? nonce,
        'bridge_id': bridgeId,
        'name': name,
        'port': metadataPort,
        'path': '/wmr',
        'hands': const ['left', 'right'],
        'version': '0.4.0',
        'auth': 'token',
      };
      socket.send(
        utf8.encode(jsonEncode(reply)),
        datagram.address,
        datagram.port,
      );
    });
    return responder;
  }

  void close() => socket.close();
}

/// A loopback stand-in for an Avahi/systemd-resolved mDNS responder.
class _MdnsResponder {
  _MdnsResponder._(this.socket);

  final RawDatagramSocket socket;
  Uint8List? lastQuery;
  int? lastSourcePort;

  int get port => socket.port;

  static Future<_MdnsResponder> start({
    String bridgeId = 'pi-mdns',
    String instance = 'pi-mdns',
    int metadataPort = 9322,
    String address = '127.0.0.1',
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final responder = _MdnsResponder._(socket);
    socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      responder.lastQuery = datagram.data;
      responder.lastSourcePort = datagram.port;
      socket.send(
        _mdnsResponse(
          bridgeId: bridgeId,
          instance: instance,
          metadataPort: metadataPort,
          address: address,
        ),
        datagram.address,
        datagram.port,
      );
    });
    return responder;
  }

  void close() => socket.close();
}

Uint8List _mdnsResponse({
  required String bridgeId,
  required String instance,
  required int metadataPort,
  required String address,
}) {
  final fqdn = '$instance.$wmrWsMdnsServiceType';
  final target = '$instance.local';
  final builder = BytesBuilder(copy: false);
  // Response, authoritative; one PTR answer and SRV/TXT/A additionals.
  builder.add(const <int>[0, 0, 0x84, 0x00, 0, 0, 0, 1, 0, 0, 0, 3]);
  _record(
    builder,
    name: wmrWsMdnsServiceType,
    type: 12,
    data: _encodeName(fqdn),
  );
  final srv = BytesBuilder(copy: false)
    ..add(const <int>[0, 0, 0, 0])
    ..add(<int>[(metadataPort >> 8) & 0xFF, metadataPort & 0xFF])
    ..add(_encodeName(target));
  _record(builder, name: fqdn, type: 33, data: srv.toBytes());
  _record(
    builder,
    name: fqdn,
    type: 16,
    data: _txtData(<String, String>{
      'id': bridgeId,
      'path': '/wmr',
      'version': '0.4.0',
      'hands': 'left,right',
    }),
  );
  _record(
    builder,
    name: target,
    type: 1,
    data: Uint8List.fromList(
      address.split('.').map(int.parse).toList(growable: false),
    ),
  );
  return builder.toBytes();
}

void _record(
  BytesBuilder builder, {
  required String name,
  required int type,
  required List<int> data,
}) {
  builder
    ..add(_encodeName(name))
    ..add(<int>[(type >> 8) & 0xFF, type & 0xFF, 0, 1, 0, 0, 0, 120])
    ..add(<int>[(data.length >> 8) & 0xFF, data.length & 0xFF])
    ..add(data);
}

Uint8List _encodeName(String name) {
  final builder = BytesBuilder(copy: false);
  for (final label in name.split('.')) {
    final bytes = utf8.encode(label);
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0);
  return builder.toBytes();
}

Uint8List _txtData(Map<String, String> values) {
  final builder = BytesBuilder(copy: false);
  for (final entry in values.entries) {
    final bytes = utf8.encode('${entry.key}=${entry.value}');
    builder
      ..addByte(bytes.length)
      ..add(bytes);
  }
  return builder.toBytes();
}

WmrWsDiscovery _loopbackDiscovery({
  required Duration timeout,
  required int udpPort,
  int mdnsPort = 1,
}) => WmrWsDiscovery(
  timeout: timeout,
  udpPort: udpPort,
  mdnsPort: mdnsPort,
  probeAddresses: <InternetAddress>[InternetAddress.loopbackIPv4],
  mdnsAddress: InternetAddress.loopbackIPv4,
);

void main() {
  const timeout = Duration(milliseconds: 200);

  test('UDP probe carries WMR_DISCOVER_V1 and a nonce', () async {
    final responder = await _UdpResponder.start(
      bridgeId: 'pi-kitchen',
      name: 'Kitchen Pi',
      metadataPort: 9321,
    );
    addTearDown(responder.close);
    final discovery = _loopbackDiscovery(
      timeout: timeout,
      udpPort: responder.port,
    );

    final endpoints = await discovery.discover();

    expect(responder.lastProbe, startsWith('$wmrWsDiscoveryProbe '));
    final nonce = responder.lastProbe!.split(' ').last;
    expect(nonce, isNotEmpty);
    expect(endpoints, hasLength(1));
    final endpoint = endpoints.single;
    expect(endpoint.host, '127.0.0.1');
    expect(endpoint.port, 9321);
    expect(endpoint.path, '/wmr');
    expect(endpoint.bridgeId, 'pi-kitchen');
    expect(endpoint.name, 'Kitchen Pi');
    expect(endpoint.resolvedDeviceId, '127.0.0.1:9321');
  });

  test('a reply with the wrong nonce is ignored', () async {
    final responder = await _UdpResponder.start(
      nonceOverride: (_) => 'not-the-nonce',
    );
    addTearDown(responder.close);
    final discovery = _loopbackDiscovery(
      timeout: timeout,
      udpPort: responder.port,
    );

    expect(await discovery.discover(), isEmpty);
  });

  test('mDNS query has the QU bit and replies become endpoints', () async {
    final responder = await _MdnsResponder.start(
      bridgeId: 'pi-mdns-1',
      instance: 'pi-mdns',
      metadataPort: 9322,
    );
    addTearDown(responder.close);
    final discovery = _loopbackDiscovery(
      timeout: timeout,
      udpPort: 1,
      mdnsPort: responder.port,
    );

    final endpoints = await discovery.discover();

    final query = responder.lastQuery!;
    expect(query.sublist(query.length - 4), <int>[
      0,
      12,
      0x80,
      0x01,
    ], reason: 'PTR question with QU set');
    expect(responder.lastSourcePort, isNot(5353));
    expect(responder.lastSourcePort, isNot(responder.port));
    expect(endpoints, hasLength(1));
    final endpoint = endpoints.single;
    expect(endpoint.host, '127.0.0.1');
    expect(endpoint.port, 9322);
    expect(endpoint.path, '/wmr');
    expect(endpoint.bridgeId, 'pi-mdns-1');
    expect(endpoint.name, 'pi-mdns');
  });

  test('scan merges static, UDP and mDNS endpoints', () async {
    final udp = await _UdpResponder.start(
      bridgeId: 'pi-udp',
      metadataPort: 9321,
    );
    final mdns = await _MdnsResponder.start(
      bridgeId: 'pi-mdns',
      metadataPort: 9322,
    );
    addTearDown(udp.close);
    addTearDown(mdns.close);
    final staticEndpoint = WmrWsEndpoint(host: '127.0.0.1', port: 1);
    final transport = WmrWsTransport(
      endpoints: [staticEndpoint],
      discovery: _loopbackDiscovery(
        timeout: timeout,
        udpPort: udp.port,
        mdnsPort: mdns.port,
      ),
    );
    addTearDown(transport.dispose);

    final results = await transport.scan().toList();

    expect(results, hasLength(3));
    expect(results.first.deviceId, staticEndpoint.resolvedDeviceId);
    expect(
      results.map((result) => result.serviceUuids),
      everyElement(<String>[wmrBridgeServiceUuid]),
    );
    final udpId = '127.0.0.1:9321';
    final mdnsId = '127.0.0.1:9322';
    expect(
      results.map((result) => result.deviceId),
      containsAll([udpId, mdnsId]),
    );
    expect(transport.endpointFor(udpId)?.bridgeId, 'pi-udp');
    expect(transport.endpointFor(mdnsId)?.bridgeId, 'pi-mdns');
  });

  test('a restarted scan re-yields discovered endpoints', () async {
    final udp = await _UdpResponder.start(
      bridgeId: 'pi-udp',
      metadataPort: 9321,
    );
    final mdns = await _MdnsResponder.start(
      bridgeId: 'pi-mdns',
      metadataPort: 9322,
    );
    addTearDown(udp.close);
    addTearDown(mdns.close);
    final staticEndpoint = WmrWsEndpoint(host: '127.0.0.1', port: 1);
    final transport = WmrWsTransport(
      endpoints: [staticEndpoint],
      discovery: _loopbackDiscovery(
        timeout: timeout,
        udpPort: udp.port,
        mdnsPort: mdns.port,
      ),
    );
    addTearDown(transport.dispose);

    final first = await transport.scan().toList();
    final second = await transport.scan().toList();

    expect(first, hasLength(3));
    expect(second, hasLength(3));
    expect(second.first.deviceId, staticEndpoint.resolvedDeviceId);
    expect(
      second.map((result) => result.deviceId),
      containsAll(['127.0.0.1:9321', '127.0.0.1:9322']),
    );
    expect(transport.endpointFor('127.0.0.1:9321')?.bridgeId, 'pi-udp');
    expect(transport.endpointFor('127.0.0.1:9322')?.bridgeId, 'pi-mdns');
  });

  test('scan with an unsupported service skips discovery', () async {
    final responder = await _UdpResponder.start();
    addTearDown(responder.close);
    final transport = WmrWsTransport(
      endpoints: const [],
      discovery: _loopbackDiscovery(timeout: timeout, udpPort: responder.port),
    );
    addTearDown(transport.dispose);

    expect(
      await transport
          .scan(withServices: ['0000180f-0000-1000-8000-00805f9b34fb'])
          .toList(),
      isEmpty,
    );
    expect(responder.lastProbe, isNull);
  });

  group('bridge identity before authentication', () {
    late FakePiServer server;

    setUp(() async {
      server = await FakePiServer.start(
        const FakePiOptions(authRequired: true, bridgeId: 'pi-real'),
      );
    });

    tearDown(() => server.stop());

    test('a matching hello bridge_id allows the token', () async {
      final endpoint = WmrWsEndpoint(
        host: '127.0.0.1',
        port: server.port,
        token: 'shared-secret',
        bridgeId: 'pi-real',
      );
      final transport = WmrWsTransport(endpoints: [endpoint]);
      addTearDown(transport.dispose);

      await transport.connect(endpoint.resolvedDeviceId);

      expect(server.messagesOfType('auth').single['token'], 'shared-secret');
    });

    test('a mismatched hello bridge_id sends no token', () async {
      final endpoint = WmrWsEndpoint(
        host: '127.0.0.1',
        port: server.port,
        token: 'shared-secret',
        bridgeId: 'pi-spoofed',
      );
      final transport = WmrWsTransport(endpoints: [endpoint]);
      addTearDown(transport.dispose);

      await expectLater(
        transport.connect(endpoint.resolvedDeviceId),
        throwsA(isA<WmrWsHandshakeException>()),
      );
      expect(server.messagesOfType('auth'), isEmpty);
    });
  });
}
