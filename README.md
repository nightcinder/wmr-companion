# wmr-companion

Flutter companion app for ESP32 (BTstack) WMR controllers. Connects over BLE GATT, shows live 3DoF orientation in a debug mode, and measures BLE latency and jitter.

Status: milestone 1 (scaffold, fake transport, debug 3D view on synthetic data). See [docs/PLAN.md](docs/PLAN.md) and [docs/PROTOCOL.md](docs/PROTOCOL.md).

```
flutter pub get
flutter analyze
flutter test
flutter run -d <device>   # BLE needs a physical phone
```

## License

MIT, see [LICENSE](LICENSE). Third-party packages (universal_ble, ector_math, Flutter) keep their own BSD-style licenses; Flutter's built-in license page lists them in the app.

