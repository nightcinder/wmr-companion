## 0.1.0

- First frozen line (pre-1.0). Optional Android Bluetooth HID gamepad output
  for `wmr_companion` hosts:
  - `HidGamepadTransport`, HID report encoding and the report descriptor.
  - Self-registering Flutter plugin (`WmrCompanionHidPlugin`), `ActivityAware`
    permission handling and the plugin's Android manifest permissions.
  - Reports `HidState.unsupported` where the plugin or permission is missing.
- Not published to pub.dev yet; see `docs/PUBLISHING.md`.
