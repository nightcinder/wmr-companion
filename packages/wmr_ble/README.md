# wmr_ble

`universal_ble` transport for the [WMR Bridge](https://github.com/nightcinder/wmr-companion),
behind the `BleTransport` seam from `wmr_core`. Android and iOS are both v1
targets; desktop and web are out of scope.

Status: **phase 3**. The transport and adapter are the same code the app used
before the package split. The sequencing is fake-adapter tested; the
`universal_ble` calls are **not verified on hardware**.

## Use

```yaml
dependencies:
  wmr_ble:
    path: packages/wmr_ble
```

```dart
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion/wmr_companion.dart';

final transport = UniversalBleTransport(adapter: UniversalBleAdapter());
final wmr = WmrCompanion(ble: transport);
// initialize, scan, connect, streams, dispose ...
```

`UniversalBleTransport` runs the bridge sequence: link, MTU request (records
the negotiated value), high connection priority where the platform supports
it, service discovery, an FF10/FF11 check, then notification setup. After an
unexpected drop it reports `BleLinkPhase.connectionLost`; reconnection is the
caller's job (`WmrCompanion` does one retry).

`FakeBleAdapter` is available from `package:wmr_ble/testing.dart` for hosts
that test their own adapter-level code without a phone.

## App lifecycle

The package does **not** import `dart:ui` or Flutter widgets. The host forwards
its lifecycle:

```dart
final listener = AppLifecycleListener(
  onStateChange: (state) => transport.handleAppLifecycle(switch (state) {
    AppLifecycleState.resumed => BleAppLifecycle.resumed,
    AppLifecycleState.inactive => BleAppLifecycle.inactive,
    AppLifecycleState.paused => BleAppLifecycle.paused,
    AppLifecycleState.detached => BleAppLifecycle.detached,
    AppLifecycleState.hidden => BleAppLifecycle.inactive,
  }),
);
```

An inactive/paused/detached host stops scanning; a resumed host restarts the
scan with the same filters. Connections are left alone, because a short
background period usually keeps the link and dropping it would turn a resume
into a reconnect.

## Permissions and adapter state

`UniversalBleAdapter` exposes the platform primitives; the host still owns the
user-facing permission rationale and the `Info.plist` / manifest declarations.

- **Android:** `BLUETOOTH_SCAN` (with `neverForLocation`) and
  `BLUETOOTH_CONNECT`; legacy `ACCESS_FINE_LOCATION` with `maxSdkVersion="30"`.
  The transport asks for runtime permissions before scanning or connecting.
  MTU 517 and high connection priority are requested after every connect and
  are best effort: Android 14+ may ignore the MTU, and the reported value is
  whatever the stack returns.
- **iOS:** `NSBluetoothAlwaysUsageDescription` in the host's `Info.plist` (and
  the older peripheral key if the host targets it). `bluetooth-central`
  background mode only if the host claims background operation. iOS chooses
  MTU and connection interval; both may be null in `BleLinkStatus`.
- **visionOS:** the same CoreBluetooth path where the OS permits it; not
  verified.
- **Adapter state:** `BleAvailability` is surfaced through the scan/connect
  preflight (`off`, `unauthorized`, `unsupported`, `resetting`) and as a typed
  `BleTransportException` phase. The host decides what to show.

`BleLinkStatus` is a snapshot for a UI: phase, device id, message, negotiated
MTU, whether high priority was requested, and non-fatal setup warnings. The
facade does not depend on it; anything that only wants controller data can
stay on `wmr_companion`.

## Tests

```sh
flutter pub get
flutter analyze
flutter test
```

The tests drive `UniversalBleTransport` through `FakeBleAdapter` and the
firmware-shaped `FakeWmrBridge` from `wmr_core`; no phone or plugin call is
needed.

## Licence

MIT. The bridge firmware is a separate, BTstack-derived project with its own
licence; this package does not include firmware.
