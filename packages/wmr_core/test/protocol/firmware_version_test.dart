import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/protocol/firmware_version.dart';
import 'package:wmr_core/protocol/gatt.dart';

const _all = WmrBridgeFeatures(
  rawStream: true,
  decodedStream: true,
  batchedStream: true,
  configBlock: true,
  echo: true,
  firmwareVersion: true,
  controllerControl: true,
);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// The document the Pi host bridge serves from FF16. It is deliberately longer
/// than [wmrFirmwareVersionMaxBytes].
Uint8List _endpointDocument({
  String type = 'wmr_ble_endpoint',
  bool includeVersion = true,
  Object? version = '0.2.4',
}) => _bytes(
  jsonEncode({
    'type': type,
    'protocol': 1,
    'bridge_id': 'pi-1',
    'name': 'WMR Bridge',
    if (includeVersion) 'version': version,
    'hosts': ['192.168.1.42'],
    'port': 8765,
    'path': '/wmr',
    'authRequired': false,
  }),
);

void main() {
  group('WmrBridgeFeatures', () {
    test('maps the FF10 characteristics case-insensitively', () {
      final features = WmrBridgeFeatures.fromCharacteristics([
        wmrBridgeStreamCharUuid.toUpperCase(),
        wmrBridgeDecodedCharUuid,
        wmrBridgeBatchedCharUuid,
        wmrBridgeConfigCharUuid,
        wmrBridgeEchoCharUuid,
        wmrBridgeVersionCharUuid,
        wmrBridgeControllerCharUuid,
        '0000abcd-0000-1000-8000-00805f9b34fb',
      ]);
      expect(features.rawStream, isTrue);
      expect(features.decodedStream, isTrue);
      expect(features.batchedStream, isTrue);
      expect(features.configBlock, isTrue);
      expect(features.echo, isTrue);
      expect(features.firmwareVersion, isTrue);
      expect(features.controllerControl, isTrue);
      expect(features.offered, WmrBridgeFeature.values.toSet());
      for (final feature in WmrBridgeFeature.values) {
        expect(features.supports(feature), isTrue);
      }
    });

    test('ignores unknown UUIDs and reports an empty table', () {
      final features = WmrBridgeFeatures.fromCharacteristics(const [
        '0000abcd-0000-1000-8000-00805f9b34fb',
      ]);
      expect(features.offered, isEmpty);
      expect(features.supports(WmrBridgeFeature.rawStream), isFalse);
      expect(WmrBridgeFeatures.none.offered, isEmpty);
    });

    test('an older bridge without FF13-FF17 still reports FF11/FF12', () {
      final features = WmrBridgeFeatures.fromCharacteristics([
        wmrBridgeStreamCharUuid,
        wmrBridgeDecodedCharUuid,
      ]);
      expect(features.rawStream, isTrue);
      expect(features.decodedStream, isTrue);
      expect(features.batchedStream, isFalse);
      expect(features.configBlock, isFalse);
      expect(features.echo, isFalse);
      expect(features.firmwareVersion, isFalse);
      expect(features.controllerControl, isFalse);
    });
  });

  group('WmrProtocolVersion', () {
    test('parses the version string FF16 serves', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        _bytes('v0.4.0-3-g41771f8'),
        features: _all,
      );
      expect(protocol.firmwareVersion, 'v0.4.0-3-g41771f8');
      expect(protocol.hasFirmwareVersion, isTrue);
      expect(protocol.firmwareVersionMalformed, isFalse);
      expect(protocol.features, same(_all));
    });

    test('tolerates one trailing NUL and surrounding whitespace', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        Uint8List.fromList([...utf8.encode(' v1.2.3 '), 0]),
        features: _all,
      );
      expect(protocol.firmwareVersion, 'v1.2.3');
      expect(protocol.firmwareVersionMalformed, isFalse);
    });

    test('accepts the 31-byte maximum', () {
      final max = 'v1.2.3-abcdef0123456789-abcdefg';
      expect(utf8.encode(max).length, wmrFirmwareVersionMaxBytes);
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        _bytes(max),
        features: _all,
      );
      expect(protocol.firmwareVersion, max);
      expect(protocol.firmwareVersionMalformed, isFalse);
    });

    test('extracts the version from the Pi BLE JSON endpoint document', () {
      final document = _endpointDocument();
      expect(document.length, greaterThan(wmrFirmwareVersionMaxBytes));
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        document,
        features: _all,
      );
      expect(protocol.firmwareVersion, '0.2.4');
      expect(protocol.hasFirmwareVersion, isTrue);
      expect(protocol.firmwareVersionMalformed, isFalse);
      expect(protocol.features, same(_all));
    });

    test('tolerates a trailing NUL after the endpoint document', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        Uint8List.fromList([..._endpointDocument(), 0]),
        features: _all,
      );
      expect(protocol.firmwareVersion, '0.2.4');
      expect(protocol.firmwareVersionMalformed, isFalse);
    });

    test('marks a non-endpoint JSON object malformed', () {
      for (final document in [
        _endpointDocument(type: 'something_else'),
        _endpointDocument(includeVersion: false),
        _endpointDocument(version: 24),
        _bytes('{"type":"wmr_ble_endpoint",'),
      ]) {
        final protocol = WmrProtocolVersion.parseFirmwareVersion(
          document,
          features: _all,
        );
        expect(protocol.firmwareVersion, isNull);
        expect(protocol.firmwareVersionMalformed, isTrue);
      }
    });

    test('marks an endpoint version that breaks the plain-string rules', () {
      for (final version in [
        '',
        'v1.2.3-abcdef0123456789-abcdefgh',
        'v1.2.3\u0001',
      ]) {
        final protocol = WmrProtocolVersion.parseFirmwareVersion(
          _endpointDocument(version: version),
          features: _all,
        );
        expect(protocol.firmwareVersion, isNull);
        expect(protocol.firmwareVersionMalformed, isTrue);
      }
    });

    test('a missing FF16 is a normal status, not malformed', () {
      final features = WmrBridgeFeatures.fromCharacteristics([
        wmrBridgeStreamCharUuid,
        wmrBridgeDecodedCharUuid,
      ]);
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        null,
        features: features,
      );
      expect(protocol.firmwareVersion, isNull);
      expect(protocol.hasFirmwareVersion, isFalse);
      expect(protocol.firmwareVersionMalformed, isFalse);
      expect(protocol.features.firmwareVersion, isFalse);
      expect(protocol.features.rawStream, isTrue);

      final explicit = WmrProtocolVersion.withoutFirmwareVersion(
        features: features,
      );
      expect(explicit.firmwareVersion, isNull);
      expect(explicit.firmwareVersionMalformed, isFalse);
    });

    test('marks an empty value malformed', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        Uint8List(0),
        features: _all,
      );
      expect(protocol.firmwareVersion, isNull);
      expect(protocol.firmwareVersionMalformed, isTrue);
    });

    test('marks a value longer than the descriptor field malformed', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        _bytes('v1.2.3-abcdef0123456789-abcdefgh'),
        features: _all,
      );
      expect(protocol.firmwareVersion, isNull);
      expect(protocol.firmwareVersionMalformed, isTrue);
    });

    test('marks invalid UTF-8 malformed instead of throwing', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        Uint8List.fromList([0xff, 0xfe, 0xfd]),
        features: _all,
      );
      expect(protocol.firmwareVersion, isNull);
      expect(protocol.firmwareVersionMalformed, isTrue);
    });

    test('marks control characters malformed instead of throwing', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        Uint8List.fromList([0x76, 0x31, 0x01, 0x32]),
        features: _all,
      );
      expect(protocol.firmwareVersion, isNull);
      expect(protocol.firmwareVersionMalformed, isTrue);
    });
  });

  group('WmrSemanticVersion', () {
    test('parses release tags and ignores git-describe build metadata', () {
      final release = WmrSemanticVersion.tryParse('v0.3.20')!;
      expect((release.major, release.minor, release.patch), (0, 3, 20));
      expect(release.isPreRelease, isFalse);
      expect(WmrSemanticVersion.tryParse(' 0.2.4 ')!.toString(), '0.2.4');
      final describe = WmrSemanticVersion.tryParse('v0.4.0-3-g41771f8')!;
      expect(
        describe,
        WmrSemanticVersion.tryParse('0.4.0'),
        reason: 'git describe counts commits after the tag, not a pre-release',
      );
      expect(describe.isPreRelease, isFalse);
      expect(
        WmrSemanticVersion.tryParse('0.4.0+sha.41771f8')!.toString(),
        '0.4.0',
      );
    });

    test('rejects strings that are not versions', () {
      for (final value in ['', 'v', '1.2', '1.2.x', '1.2.3.4', 'v1.2.3-']) {
        expect(WmrSemanticVersion.tryParse(value), isNull, reason: value);
      }
    });

    test('rejects components that overflow an int instead of throwing', () {
      for (final value in [
        '9999999999999999999.0.0',
        '0.9999999999999999999.0',
        '0.0.9999999999999999999',
      ]) {
        expect(WmrSemanticVersion.tryParse(value), isNull, reason: value);
      }
    });

    test('orders releases and pre-releases by SemVer', () {
      final ordered = [
        '0.3.9',
        '0.3.10',
        '0.4.0-beta.2',
        '0.4.0-beta.11',
        '0.4.0-rc.1',
        '0.4.0',
      ].map((value) => WmrSemanticVersion.tryParse(value)!).toList();
      for (var i = 1; i < ordered.length; i++) {
        expect(
          ordered[i - 1] < ordered[i],
          isTrue,
          reason: '${ordered[i - 1]} < ${ordered[i]}',
        );
        expect(ordered[i - 1] == ordered[i], isFalse);
      }
    });

    test('a protocol version exposes its parsed semantic version', () {
      final protocol = WmrProtocolVersion.parseFirmwareVersion(
        _endpointDocument(version: '0.3.19'),
        features: _all,
      );
      expect(protocol.semanticVersion!.toString(), '0.3.19');
      expect(
        WmrProtocolVersion.parseFirmwareVersion(
          null,
          features: _all,
        ).semanticVersion,
        isNull,
      );
    });
  });
}
