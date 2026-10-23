# Changelog

## 0.1.0

- Initial release of the Android Bluetooth HID gamepad output plugin for `wmr_companion` hosts.
- `HidGamepadTransport`: platform channel interface to Android's `BluetoothHidDevice` API for registration, host connection state management, and input report transmission.
- `encodeHidReport`: encodes `GamepadState` into standard 9-byte HID gamepad input reports.
- Self-registering Android Flutter plugin (`WmrCompanionHidPlugin`) handling Activity lifecycle and Android 12+ (API 31+) runtime Bluetooth permissions (`BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`).
- Framework-agnostic plugin boundary: free of Riverpod and host application dependencies.
