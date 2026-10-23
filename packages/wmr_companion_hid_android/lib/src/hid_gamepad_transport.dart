import 'dart:async';

import 'package:flutter/services.dart';

import 'hid_report.dart';

/// Lifecycle of the Bluetooth HID device role.
enum HidState {
  /// No Android plugin (other platform) or Android older than 9.
  unsupported,

  /// Not registered with the Bluetooth stack.
  idle,

  /// Registered as a HID device, no host connected.
  registered,

  /// A host is connected; reports reach it.
  connected,

  /// The last operation failed; see [HidStatus.message].
  error,
}

class HidStatus {
  const HidStatus(this.state, {this.deviceName, this.message});

  final HidState state;

  /// Name of the connected host, when [state] is [HidState.connected].
  final String? deviceName;
  final String? message;

  @override
  bool operator ==(Object other) =>
      other is HidStatus &&
      other.state == state &&
      other.deviceName == deviceName &&
      other.message == message;

  @override
  int get hashCode => Object.hash(state, deviceName, message);
}

/// A bonded Bluetooth device the phone can connect to as a HID device.
class HidHost {
  const HidHost(this.name, this.address);

  final String name;
  final String address;
}

/// The phone as a Bluetooth HID gamepad. Kept behind an interface so the
/// platform side (Android `BluetoothHidDevice`) can be swapped or faked.
abstract class HidGamepadTransport {
  /// Status changes; emits the current status first on listen.
  Stream<HidStatus> get status;

  /// Asks for the Bluetooth permission if needed and registers the gamepad.
  Future<void> start();

  /// Disconnects and unregisters.
  Future<void> stop();

  /// Sends one input report (payload only; the report ID is fixed).
  Future<void> sendReport(Uint8List data);

  Future<List<HidHost>> bondedHosts();

  /// Connects to a bonded host by address.
  Future<void> connect(String address);

  Future<void> disconnect();

  /// Asks the user to make the phone discoverable so a host can pair.
  Future<void> requestDiscoverable();
}

/// Talks to `HidGamepadPlugin.kt` over a method and an event channel. Any
/// platform without the plugin reports [HidState.unsupported].
class MethodChannelHidGamepad implements HidGamepadTransport {
  MethodChannelHidGamepad({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(methodChannelName),
      _events = events ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'wmr_companion/hid_gamepad';
  static const eventChannelName = 'wmr_companion/hid_gamepad/events';

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Stream<HidStatus> get status async* {
    try {
      // An event channel without a handler fails silently, so probe with a
      // method call first.
      await _methods.invokeMethod<void>('ping');
      await for (final e in _events.receiveBroadcastStream()) {
        yield parseStatus(e);
      }
    } on MissingPluginException {
      yield const HidStatus(HidState.unsupported);
    } on PlatformException catch (e) {
      yield HidStatus(HidState.error, message: e.message ?? e.code);
    }
  }

  /// Event payload from the plugin: `{state, device?, message?}`.
  static HidStatus parseStatus(Object? event) {
    if (event is! Map) {
      return const HidStatus(HidState.error, message: 'bad status event');
    }
    final state = HidState.values.asNameMap()[event['state']];
    if (state == null) {
      return HidStatus(
        HidState.error,
        message: 'unknown state ${event['state']}',
      );
    }
    return HidStatus(
      state,
      deviceName: event['device'] as String?,
      message: event['message'] as String?,
    );
  }

  @override
  Future<void> start() => _call('start', {'descriptor': hidReportDescriptor});

  @override
  Future<void> stop() => _call('stop');

  @override
  Future<void> sendReport(Uint8List data) =>
      _call('sendReport', {'id': hidReportId, 'data': data});

  @override
  Future<List<HidHost>> bondedHosts() async {
    final raw = await _methods.invokeListMethod<Map<Object?, Object?>>(
      'bondedHosts',
    );
    return [
      for (final m in raw ?? const <Map<Object?, Object?>>[])
        HidHost(m['name'] as String? ?? '', m['address'] as String),
    ];
  }

  @override
  Future<void> connect(String address) => _call('connect', address);

  @override
  Future<void> disconnect() => _call('disconnect');

  @override
  Future<void> requestDiscoverable() => _call('requestDiscoverable');

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _methods.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Not Android: nothing to do, the status stream says unsupported.
    }
  }
}
