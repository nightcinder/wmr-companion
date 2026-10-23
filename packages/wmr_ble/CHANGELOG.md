## 0.1.0

- First frozen line (pre-1.0). `universal_ble` adapter and transport, extracted
  from the app:
  - `BleAdapter` seam and `UniversalBleAdapter`.
  - `UniversalBleTransport` with scan/connect/MTU/priority/subscribe, typed
    transport errors and `BleLinkStatus`.
  - `BleAppLifecycle` for pause/resume of scanning, forwarded by the host.
  - `FakeBleAdapter` via `package:wmr_ble/testing.dart`.
- Not published to pub.dev yet; see `docs/PUBLISHING.md`.
