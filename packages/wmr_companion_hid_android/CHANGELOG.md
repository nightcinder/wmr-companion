# Changelog

## Unreleased

- `encodeHidReport` packs buttons in Android/Linux HID slot order, matching the unreleased WMR_Bridge firmware change (`src/wmr_hid.c`, documented in its `docs/HID_GAMEPAD.md`; firmware 0.3.2 and earlier packed model order): C (bit 2) and Z (bit 5) are reserved and stay clear. The shared HID vectors are updated to match.
- Migrate the Android plugin to AGP 9 built-in Kotlin: drop the Kotlin Gradle Plugin classpath and `org.jetbrains.kotlin.android`, and require Flutter 3.44 or later.

## 0.2.2

- Version aligned with the v0.2.2 release; `wmr_companion` and `wmr_core` constraints raised to `^0.2.2`. No breaking public API change.

## 0.2.1

- Version aligned with the v0.2.1 gate and harness release; `wmr_companion` constraint raised to `^0.2.1`. No breaking public API change.

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Initial release of the Android Bluetooth HID gamepad output plugin for `wmr_companion` hosts.
- `HidGamepadTransport`: platform channel interface to Android's `BluetoothHidDevice` API for registration, host connection state management, and input report transmission.
- `encodeHidReport`: encodes `GamepadState` into standard 9-byte HID gamepad input reports.
- Self-registering Android Flutter plugin (`WmrCompanionHidPlugin`) handling Activity lifecycle and Android 12+ (API 31+) runtime Bluetooth permissions (`BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`).
- Framework-agnostic plugin boundary: free of Riverpod and host application dependencies.
