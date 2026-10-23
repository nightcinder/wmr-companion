import 'dart:async';
import 'dart:typed_data';

import '../ble/ble_transport.dart';
import '../protocol/config_block.dart';
import '../protocol/gatt.dart';

enum ConfigReadFailure {
  /// The bridge has no FF13 (firmware older than WMR_Bridge #17).
  unsupported,

  /// The bridge reports the block as not read, or still reading, after the
  /// wait ([ConfigReadResult.state]).
  notReady,

  /// The bridge could not read the block from the controller.
  bridgeFailed,

  /// A GATT read or write failed ([ConfigClient.lastError]).
  transport,

  /// A value was malformed, or windows disagreed with each other.
  inconsistent,

  /// The reassembled blob does not match the CRC-32 in the header.
  crcMismatch,
}

/// Exactly one of [blob] and [failure].
class ConfigReadResult {
  const ConfigReadResult.ok(Uint8List this.blob, this.crc)
    : failure = null,
      state = ConfigState.ready,
      detail = null;
  const ConfigReadResult.failed(
    ConfigReadFailure this.failure, {
    this.state,
    this.detail,
  }) : blob = null,
       crc = null;

  final Uint8List? blob;

  /// CRC-32 from the header, checked against [blob].
  final int? crc;
  final ConfigReadFailure? failure;
  final ConfigState? state;
  final String? detail;
}

/// Reads a hand's controller config block over the bridge's FF13.
///
/// Per window: write the cursor `(hand, offset)` with response, read the
/// value. Windows are at most 496 data bytes. Independent of the FF11/FF12/
/// FF14 stream and its exclusion. Not run against the bridge from the app.
class ConfigClient {
  ConfigClient(
    this.transport,
    this.deviceId, {
    this.readyTimeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 500),
  });

  final BleTransport transport;
  final String deviceId;

  /// How long to wait for a block that is still being read from the
  /// controller.
  final Duration readyTimeout;
  final Duration pollInterval;

  Object? lastError;

  Future<bool> _supported() async {
    final services = await transport.discoverServices(deviceId);
    return services.any(
      (s) =>
          s.uuid.toLowerCase() == wmrBridgeServiceUuid &&
          s.characteristicUuids.any(
            (c) => c.toLowerCase() == wmrBridgeConfigCharUuid,
          ),
    );
  }

  Future<ConfigWindow?> _window(int hand, int offset) async {
    await transport.write(
      deviceId,
      wmrBridgeServiceUuid,
      wmrBridgeConfigCharUuid,
      encodeConfigCursor(hand, offset),
    );
    final bytes = await transport.read(
      deviceId,
      wmrBridgeServiceUuid,
      wmrBridgeConfigCharUuid,
    );
    return parseConfigWindow(bytes).window;
  }

  /// Reads the block of [hand] (0 LEFT, 1 RIGHT).
  Future<ConfigReadResult> read(int hand) async {
    try {
      if (!await _supported()) {
        return const ConfigReadResult.failed(ConfigReadFailure.unsupported);
      }
      final deadline = transport.clock.nowUs + readyTimeout.inMicroseconds;
      ConfigWindow? first;
      while (true) {
        first = await _window(hand, 0);
        if (first == null || first.hand != hand) {
          return const ConfigReadResult.failed(
            ConfigReadFailure.inconsistent,
            detail: 'unparseable header or wrong hand',
          );
        }
        if (first.state == ConfigState.ready) break;
        if (first.state == ConfigState.failed) {
          return ConfigReadResult.failed(
            ConfigReadFailure.bridgeFailed,
            state: first.state,
          );
        }
        if (transport.clock.nowUs >= deadline) {
          return ConfigReadResult.failed(
            ConfigReadFailure.notReady,
            state: first.state,
          );
        }
        await Future<void>.delayed(pollInterval);
      }

      final total = first.totalLen;
      final crc = first.crc32;
      final blob = Uint8List(total);
      var got = 0;
      ConfigWindow w = first;
      while (true) {
        final expected = total - got < wmrConfigWindowMax
            ? total - got
            : wmrConfigWindowMax;
        if (w.state != ConfigState.ready ||
            w.totalLen != total ||
            w.crc32 != crc ||
            w.offset != got ||
            w.data.length != expected) {
          return ConfigReadResult.failed(
            ConfigReadFailure.inconsistent,
            state: w.state,
            detail:
                'window at $got: state ${w.state.name}, total ${w.totalLen}, '
                'offset ${w.offset}, ${w.data.length} bytes (expected '
                '$expected)',
          );
        }
        blob.setRange(got, got + expected, w.data);
        got += expected;
        if (got >= total) break;
        final next = await _window(hand, got);
        if (next == null) {
          return const ConfigReadResult.failed(
            ConfigReadFailure.inconsistent,
            detail: 'unparseable window',
          );
        }
        w = next;
      }
      if (crc32(blob) != crc) {
        return ConfigReadResult.failed(
          ConfigReadFailure.crcMismatch,
          state: ConfigState.ready,
          detail:
              'header ${crc.toRadixString(16)}, got '
              '${crc32(blob).toRadixString(16)}',
        );
      }
      return ConfigReadResult.ok(blob, crc);
    } catch (e) {
      lastError = e;
      return const ConfigReadResult.failed(ConfigReadFailure.transport);
    }
  }
}
