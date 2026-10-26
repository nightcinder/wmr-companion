# Changelog

## 0.2.0

- Version aligned with the v0.2.0 release; no breaking public API change.

## 0.1.0

- Initial release of the `universal_ble` transport package for the WMR Bridge.
- `UniversalBleTransport` implementing the `BleTransport` seam from `wmr_core`.
- Sequenced connection establishment: device connection, MTU negotiation, connection priority requests, service/characteristic discovery, and notification subscription.
- Framework-agnostic host lifecycle integration (`BleAppLifecycle` / `handleAppLifecycle`) for managing scan pauses and resumes across app lifecycle transitions.
- Mutually exclusive stream mode toggling with CCC descriptor zeroing between FF11, FF12, and FF14 characteristics.
- Multi-bridge support managing concurrent connections to dual ESP32 bridges.
- `FakeBleAdapter` in `package:wmr_ble/testing.dart` for adapter-level unit testing without physical Bluetooth hardware.
