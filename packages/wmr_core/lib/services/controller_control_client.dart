import 'dart:async';

import '../ble/ble_transport.dart';
import '../protocol/controller_control.dart';
import '../protocol/gatt.dart';

/// The outcome of one FF17 write. Exactly one of [result] and [error] is set;
/// [result] is `ok` on success and the firmware's code on a refusal, when the
/// status read after the failure could supply it.
class ControllerCommandOutcome {
  const ControllerCommandOutcome.ok()
    : result = ControllerResult.ok,
      error = null;
  const ControllerCommandOutcome.failed(this.result, this.error);

  final ControllerResult? result;
  final Object? error;

  bool get isOk => result == ControllerResult.ok && error == null;
}

/// Controls the ESP32's controller scanning and connections over FF17
/// (docs/PROTOCOL.md, "Controller scan and status v2"). Independent of the
/// FF11/FF12/FF14 stream exclusion.
///
/// The firmware refuses a write with ATT error `0x80 + result code` and
/// records the code in the status, so a failed write reads the status once to
/// report the firmware's own reason rather than the platform's wording.
class ControllerControlClient {
  ControllerControlClient(this.transport, this.deviceId);

  final BleTransport transport;
  final String deviceId;

  /// True when the connected bridge advertises FF17. Firmware before v0.1.1
  /// does not.
  Future<bool> isSupported() async {
    final services = await transport.discoverServices(deviceId);
    return services.any(
      (s) =>
          s.uuid.toLowerCase() == wmrBridgeServiceUuid &&
          s.characteristicUuids.any(
            (c) => c.toLowerCase() == wmrBridgeControllerCharUuid,
          ),
    );
  }

  Future<ControllerStatusV2> readStatus() async {
    final value = await transport.read(
      deviceId,
      wmrBridgeServiceUuid,
      wmrBridgeControllerCharUuid,
    );
    final status = ControllerStatusV2.parse(value);
    if (status == null) {
      throw FormatException('FF17 status is ${value.length} bytes, need 20');
    }
    return status;
  }

  /// Status notifications. Malformed values are dropped; a subscription
  /// failure is delivered as an error on the stream.
  Stream<ControllerStatusV2> statusStream() => transport
      .subscribe(deviceId, wmrBridgeServiceUuid, wmrBridgeControllerCharUuid)
      .map((notification) => ControllerStatusV2.parse(notification.value))
      .where((s) => s != null)
      .cast<ControllerStatusV2>();

  Future<void> unsubscribeStatus() => transport.unsubscribe(
    deviceId,
    wmrBridgeServiceUuid,
    wmrBridgeControllerCharUuid,
  );

  /// Sends [command] with response. Never throws for a firmware refusal; a
  /// transport failure that is not an ATT refusal comes back as
  /// [ControllerCommandOutcome.error] with no [ControllerCommandOutcome.result].
  Future<ControllerCommandOutcome> send(
    ControllerCommand command, {
    int? hand,
  }) async {
    try {
      await transport.write(
        deviceId,
        wmrBridgeServiceUuid,
        wmrBridgeControllerCharUuid,
        encodeControllerCommand(command, hand: hand),
      );
      return const ControllerCommandOutcome.ok();
    } catch (error) {
      ControllerStatusV2? status;
      try {
        status = await readStatus();
      } catch (_) {
        status = null;
      }
      // Only report a result the firmware recorded for *this* command. A
      // transport failure (link drop, GATT busy) leaves the previous value
      // there, usually `ok`, which must not be shown as the reason.
      final refusal = error is ControllerCommandException
          ? error.result
          : status != null &&
                status.lastCommand == command &&
                status.lastResult != ControllerResult.ok
          ? status.lastResult
          : null;
      return ControllerCommandOutcome.failed(refusal, error);
    }
  }
}
