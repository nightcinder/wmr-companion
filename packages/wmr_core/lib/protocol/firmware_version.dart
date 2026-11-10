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

/// `esp_app_desc_t.version` is 32 bytes including its terminator, so a plain
/// version string from FF16 is at most 31 bytes. The firmware refuses a longer
/// `PROJECT_VER` instead of letting ESP-IDF truncate it.
///
/// The Raspberry Pi BLE host bridge serves a JSON endpoint document from FF16
/// instead of a plain string. That document is longer than this cap; only its
/// `"version"` value is held to it.
const int wmrFirmwareVersionMaxBytes = 31;

/// The `"type"` of the endpoint document the Pi host bridge serves from FF16.
const String wmrBleEndpointDocumentType = 'wmr_ble_endpoint';

/// One bridge or release version: `major.minor.patch` with an optional SemVer
/// pre-release suffix. Build metadata is ignored when comparing.
///
/// The bridge reports plain versions (`0.3.19`), git-describe strings
/// (`v0.4.0-3-g41771f8`) and GitHub serves release tags (`v0.3.20`); all three
/// parse. A git-describe `-N-gSHA` suffix counts commits after the tag, not a
/// pre-release, so it is treated as build metadata and compares equal to the
/// tag it was cut from. A real pre-release (`0.4.0-rc.1`) still sorts below the
/// release, as SemVer requires.
class WmrSemanticVersion implements Comparable<WmrSemanticVersion> {
  const WmrSemanticVersion(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease = const [],
  });

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated pre-release identifiers, empty for a release version.
  final List<String> preRelease;

  static final RegExp _pattern = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// `git describe` output: N commits after the tag, then the abbreviated SHA.
  static final RegExp _gitDescribeSuffix = RegExp(r'^\d+-g[0-9a-f]+$');

  /// Parses [text] after trimming it and allowing one leading `v`/`V`.
  /// Returns null for anything that is not a version, including numeric
  /// components that do not fit an [int], so callers can fall back to showing
  /// the raw string.
  static WmrSemanticVersion? tryParse(String text) {
    var value = text.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    final match = _pattern.firstMatch(value);
    if (match == null) return null;
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) return null;
    final pre = match.group(4);
    final identifiers = pre == null || _gitDescribeSuffix.hasMatch(pre)
        ? const <String>[]
        : pre.split('.');
    if (identifiers.any((identifier) => identifier.isEmpty)) return null;
    return WmrSemanticVersion(major, minor, patch, preRelease: identifiers);
  }

  bool get isPreRelease => preRelease.isNotEmpty;

  @override
  int compareTo(WmrSemanticVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a < b ? -1 : 1;
    }
    if (preRelease.isEmpty || other.preRelease.isEmpty) {
      if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
      return preRelease.isEmpty ? 1 : -1;
    }
    final shared = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < shared; i++) {
      final a = preRelease[i];
      final b = other.preRelease[i];
      final aNumber = int.tryParse(a);
      final bNumber = int.tryParse(b);
      if (aNumber != null && bNumber != null) {
        if (aNumber != bNumber) return aNumber < bNumber ? -1 : 1;
      } else if (aNumber != null) {
        // Numeric identifiers sort below alphanumeric ones.
        return -1;
      } else if (bNumber != null) {
        return 1;
      } else {
        final order = a.compareTo(b);
        if (order != 0) return order < 0 ? -1 : 1;
      }
    }
    if (preRelease.length == other.preRelease.length) return 0;
    return preRelease.length < other.preRelease.length ? -1 : 1;
  }

  bool operator >(WmrSemanticVersion other) => compareTo(other) > 0;

  bool operator <(WmrSemanticVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is WmrSemanticVersion && compareTo(other) == 0;

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(preRelease));

  @override
  String toString() =>
      '$major.$minor.$patch'
      '${preRelease.isEmpty ? '' : '-${preRelease.join('.')}'}';
}

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

  /// FF17: controller control and status v2 (WMR_Bridge #70).
  controllerControl,
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
    this.controllerControl = false,
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
      controllerControl: seen.contains(wmrBridgeControllerCharUuid),
    );
  }

  final bool rawStream;
  final bool decodedStream;
  final bool batchedStream;
  final bool configBlock;
  final bool echo;
  final bool firmwareVersion;
  final bool controllerControl;

  /// Whether [feature] is offered.
  bool supports(WmrBridgeFeature feature) => switch (feature) {
    WmrBridgeFeature.rawStream => rawStream,
    WmrBridgeFeature.decodedStream => decodedStream,
    WmrBridgeFeature.batchedStream => batchedStream,
    WmrBridgeFeature.configBlock => configBlock,
    WmrBridgeFeature.echo => echo,
    WmrBridgeFeature.firmwareVersion => firmwareVersion,
    WmrBridgeFeature.controllerControl => controllerControl,
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

  /// The FF16 version, trimmed of a trailing NUL and surrounding whitespace.
  /// For a JSON endpoint document this is its `"version"` value. Null when the
  /// bridge has no FF16 or the value was malformed.
  final String? firmwareVersion;

  /// True when FF16 was present but unusable: empty, a plain value longer than
  /// [wmrFirmwareVersionMaxBytes], not valid UTF-8, containing control
  /// characters, or a JSON endpoint document without a usable `"version"`.
  /// Informational: the link is unaffected.
  final bool firmwareVersionMalformed;

  /// The feature matrix derived from the GATT table.
  final WmrBridgeFeatures features;

  /// Whether a usable version string was reported.
  bool get hasFirmwareVersion => firmwareVersion != null;

  /// [firmwareVersion] parsed for ordering, or null when FF16 is absent,
  /// malformed, or not a version string. A git-describe build still parses,
  /// its suffix becoming a pre-release.
  WmrSemanticVersion? get semanticVersion {
    final value = firmwareVersion;
    return value == null ? null : WmrSemanticVersion.tryParse(value);
  }

  /// Decodes an FF16 read.
  ///
  /// [value] is null when the bridge has no FF16 or the read failed; that is
  /// not malformed. Two payload shapes are accepted:
  ///
  /// * a plain UTF-8 version string of at most [wmrFirmwareVersionMaxBytes]
  ///   bytes, as the ESP32 firmware serves;
  /// * a JSON endpoint document whose `"type"` is
  ///   [wmrBleEndpointDocumentType], as the Pi host bridge serves; its
  ///   `"version"` value is extracted before the plain-string cap applies.
  ///
  /// The firmware writes no terminator, but one trailing NUL is tolerated
  /// because a platform stack may add one. Unknown bytes are not fatal: the
  /// version becomes null and [firmwareVersionMalformed] is set.
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
    if (bytes.isEmpty) {
      return WmrProtocolVersion(
        features: features,
        firmwareVersionMalformed: true,
      );
    }
    if (_firstNonWhitespaceByte(bytes) == 0x7b) {
      return _parseEndpointDocument(bytes, features: features);
    }
    if (bytes.length > wmrFirmwareVersionMaxBytes) {
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
    return _fromVersionText(text, features: features);
  }

  /// Decodes the Pi host bridge's FF16 endpoint document and extracts its
  /// `"version"`. Anything else served from FF16 is malformed.
  static WmrProtocolVersion _parseEndpointDocument(
    Uint8List bytes, {
    required WmrBridgeFeatures features,
  }) {
    final malformed = WmrProtocolVersion(
      features: features,
      firmwareVersionMalformed: true,
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      return malformed;
    }
    if (decoded is! Map) return malformed;
    if (decoded['type'] != wmrBleEndpointDocumentType) return malformed;
    final version = decoded['version'];
    if (version is! String) return malformed;
    return _fromVersionText(version.trim(), features: features);
  }

  static WmrProtocolVersion _fromVersionText(
    String text, {
    required WmrBridgeFeatures features,
  }) {
    if (text.isEmpty ||
        utf8.encode(text).length > wmrFirmwareVersionMaxBytes ||
        _hasControlCharacter(text)) {
      return WmrProtocolVersion(
        features: features,
        firmwareVersionMalformed: true,
      );
    }
    return WmrProtocolVersion(features: features, firmwareVersion: text);
  }

  static int? _firstNonWhitespaceByte(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) {
        return byte;
      }
    }
    return null;
  }

  static bool _hasControlCharacter(String text) =>
      text.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}
