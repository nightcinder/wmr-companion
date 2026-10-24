# wmr_companion example

The smallest useful host: one `WmrCompanion`, a connect, and a `StreamBuilder`
over `wmr.gamepad`. It runs on the fake transport, so it shows controllers
without a phone; to use a real bridge, replace `FakeTransport` with
`UniversalBleTransport` from `wmr_ble` and keep the rest.

```sh
flutter pub get
flutter run
```

This is the phase-4 reference example from `docs/LIBRARY.md`. The full
diagnostic app lives in `apps/wmr_companion_app`.
