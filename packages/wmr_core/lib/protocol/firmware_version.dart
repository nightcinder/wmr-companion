/// The bridge's firmware version (FF16) and the FF characteristics its GATT
/// table offers.
///
/// Mirrors WMR_Bridge `wmr_bridge.gatt`, `src/wmr_transport.c` and
/// docs/PROTOCOL.md "Firmware version, FF16" on `WMR_Bridge@41771f8`
/// (PR #38). Pure Dart. None of this is a hardware claim.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'gatt.dart';

/// `esp_app_desc_t.version` is 32 bytes including its terminator, so the value
/// FF16 serves is at most 31 bytes. The firmware refuses a longer
/// `PROJECT_VER` instead of letting ESP-IDF truncate it.
const int wmrFirmwareVersionMaxBytes = 31;

/// The FF characteristics a bridge offers. FF11 and FF12 are on every known
/// firmware; the others arrived later and are optional.
enum WmrBridgeFeature {
  /// FF11: raw fragmented frames, read status and notify.
  rawStream,

  /// FF12: decoded 56-byte records.
  decodedStream,

  /// FF14: batched decoded records (needs firmware with batching and an ATT
  /// MTU of at least 61).
  batchedStream,

  /// FF13: controller config block (calibration).
  configBlock,

  /// FF15: echo / round-trip measurement.
  echo,

  /// FF16: the packaged firmware version (WMR_Bridge #38).
  firmwareVersion,
}

/// Which characteristics the connected bridge's GATT table offers.
///
/// This is the capability matrix: a characteristic that is present works
/// regardless of the firmware version string, and one that is absent cannot be
/// used. The version string from [WmrProtocolVersion.firmwareVersion] is
/// informational; do not parse it to decide what the bridge supports.
class WmrBridgeFeatures {
  const WmrBridgeFeatures({
    this.rawStream = false,
    this.decodedStream = false,
    this.batchedStream = false,
    this.configBlock = false,
    this.echo = false,
    this.firmwareVersion = false,
  });

  /// A bridge whose characteristics were not discovered.
  static const WmrBridgeFeatures none = WmrBridgeFeatures();

  /// Derives the set from the characteristic UUIDs of the FF10 service.
  /// Unknown UUIDs are ignored. Case-insensitive.
  factory WmrBridgeFeatures.fromCharacteristics(Iterable<String> uuids) {
    final seen = {for (final uuid in uuids) uuid.toLowerCase()};
    return WmrBridgeFeatures(
      rawStream: seen.contains(wmrBridgeStreamCharUuid),
      decodedStream: seen.contains(wmrBridgeDecodedCharUuid),
      batchedStream: seen.contains(wmrBridgeBatchedCharUuid),
      configBlock: seen.contains(wmrBridgeConfigCharUuid),
      echo: seen.contains(wmrBridgeEchoCharUuid),
      firmwareVersion: seen.contains(wmrBridgeVersionCharUuid),
    );
  }

  final bool rawStream;
  final bool decodedStream;
  final bool batchedStream;
  final bool configBlock;
  final bool echo;
  final bool firmwareVersion;

  /// Whether [feature] is offered.
  bool supports(WmrBridgeFeature feature) => switch (feature) {
    WmrBridgeFeature.rawStream => rawStream,
    WmrBridgeFeature.decodedStream => decodedStream,
    WmrBridgeFeature.batchedStream => batchedStream,
    WmrBridgeFeature.configBlock => configBlock,
    WmrBridgeFeature.echo => echo,
    WmrBridgeFeature.firmwareVersion => firmwareVersion,
  };

  /// The offered features, in enum order.
  Set<WmrBridgeFeature> get offered => {
    for (final feature in WmrBridgeFeature.values)
      if (supports(feature)) feature,
  };
}

/// What the bridge reports about itself: its firmware version string, when
/// FF16 exists, and its feature set from the GATT table.
///
/// A bridge without FF16 is an older firmware and a normal status, not an
/// error. A value that cannot be decoded is marked
/// [firmwareVersionMalformed] and the link keeps working; neither case throws.
class WmrProtocolVersion {
  const WmrProtocolVersion({
    required this.features,
    this.firmwareVersion,
    this.firmwareVersionMalformed = false,
  });

  /// No usable version string: FF16 is absent (older firmware) or its read
  /// failed. [features] still describe what the bridge offers.
  const WmrProtocolVersion.withoutFirmwareVersion({required this.features})
    : firmwareVersion = null,
      firmwareVersionMalformed = false;

  /// The FF16 value, trimmed of a trailing NUL and surrounding whitespace.
  /// Null when the bridge has no FF16 or the value was malformed.
  final String? firmwareVersion;

  /// True when FF16 was present but its value was empty, longer than
  /// [wmrFirmwareVersionMaxBytes], not valid UTF-8 or contained control
  /// characters. Informational: the link is unaffected.
  final bool firmwareVersionMalformed;

  /// The feature matrix derived from the GATT table.
  final WmrBridgeFeatures features;

  /// Whether a usable version string was reported.
  bool get hasFirmwareVersion => firmwareVersion != null;

  /// Decodes an FF16 read.
  ///
  /// [value] is null when the bridge has no FF16 or the read failed; that is
  /// not malformed. The firmware writes no terminator, but one trailing NUL is
  /// tolerated because a platform stack may add one. Unknown bytes are not
  /// fatal: the version becomes null and [firmwareVersionMalformed] is set.
  static WmrProtocolVersion parseFirmwareVersion(
    Uint8List? value, {
    required WmrBridgeFeatures features,
  }) {
    if (value == null) {
      return WmrProtocolVersion.withoutFirmwareVersion(features: features);
    }
    var bytes = value;
    if (bytes.isNotEmpty && bytes.last == 0) {
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    if (bytes.isEmpty || bytes.length > wmrFirmwareVersionMaxBytes) {
      return WmrProtocolVersion(
        features: features,
        firmwareVersionMalformed: true,
      );
    }
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false).trim();
    } on FormatException {
      return WmrProtocolVersion(
        features: features,
        firmwareVersionMalformed: true,
      );
    }
    if (text.isEmpty || _hasControlCharacter(text)) {
      return WmrProtocolVersion(
        features: features,
        firmwareVersionMalformed: true,
      );
    }
    return WmrProtocolVersion(features: features, firmwareVersion: text);
  }

  static bool _hasControlCharacter(String text) =>
      text.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}
