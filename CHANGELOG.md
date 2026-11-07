# Changelog

All notable changes to the WMR Companion Dart packages. Each package also
keeps its own changelog; this file records the release as a whole.

## 0.3.0

The first release since 0.2.2. All twelve packages move to 0.3.0 and their
inter-package constraints to `^0.3.0`. The reference app stays on its own
release line (`0.3.18+23`).

- FF16 protocol version and feature-matrix reporting in `wmr_core` and
  `wmr_companion` (`WmrProtocolVersion`, `WmrBridgeFeatures`).
- FF17 controller control in `wmr_core` (`ControllerControlClient`,
  `ControllerCommand`, `ControllerResult`, `ControllerStatusV2`) and the
  `WmrCompanion` facade, plus a reconnect backoff.
- Android XR head and hand tracking in `wmr_tracking` and
  `wmr_tracking_android_xr`, with dispatch across Android XR, VITURE and
  XREAL.
- VITURE and XREAL backends start when the glasses model has not been reported
  yet; the VITURE export requires stereo 3D (SpaceWalker).
- `wmr_ble` scans also list system-connected devices, so a bridge held as a
  HID gamepad is still discovered.
- `wmr_companion_hid_android` packs HID buttons in Android/Linux slot order,
  matching WMR Bridge firmware 0.3.3 and later.
- Android plugins migrate to AGP 9 built-in Kotlin and require Flutter 3.44 or
  later.

See `packages/*/CHANGELOG.md` for per-package detail.
