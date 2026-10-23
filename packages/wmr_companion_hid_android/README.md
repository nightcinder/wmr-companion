# wmr_companion_hid_android

Optional Android **Bluetooth HID gamepad output** for a
[`wmr_companion`](../wmr_companion/README.md) host: the phone appears as a
Bluetooth gamepad to a PC or console. It is not required for in-process
controller input, and it does not exist on iOS (no public HID API).

Status: **phase 7**. The Dart transport/report moved from the reference app and
the Android code is now a self-registering Flutter plugin. The behaviour is
the same as before; it is **not verified on hardware**, and some vendors ship
without the HID device profile.

## Use

```yaml
dependencies:
  wmr_companion_hid_android:
    path: packages/wmr_companion_hid_android
```

```dart
final hid = MethodChannelHidGamepad();
await for (final status in hid.status) {
  // unsupported | idle | registered | connected | error
}
await hid.start();                  // registers the descriptor
await hid.connect('AA:BB:CC:DD:EE:FF');
await hid.sendReport(encodeHidReport(gamepadState));
await hid.stop();
```

`encodeHidReport`/`hidReportDescriptor` are pure Dart and usable without a
platform. The plugin uses the same method/event channels as before
(`wmr_companion/hid_gamepad` and `.../events`), so the app's Riverpod adapter
did not need to change.

## Platform notes

- Android 9+ (`BluetoothHidDevice`). The plugin declares `BLUETOOTH_CONNECT`,
  `BLUETOOTH_ADVERTISE` (for `requestDiscoverable` on API 31+) and the legacy
  Bluetooth permissions for API <= 30; the host still explains why it needs
  them.
- The plugin is `ActivityAware` and handles its own permission result, so the
  host does not need to override `onRequestPermissionsResult`.
- iOS: not supported; `MethodChannelHidGamepad.status` reports `unsupported`
  when the plugin is missing.
- The HID descriptor is a generic gamepad. How a host names the buttons is
  host-specific and untested.

## Tests

```sh
flutter pub get
flutter analyze
flutter test
```

The tests cover report encoding, descriptor shape, channel arguments and
status parsing. Native HID registration is not exercised without a phone.

## Licence

MIT. The bridge firmware is separate (BTstack-derived, non-commercial); this
package does not include firmware.
