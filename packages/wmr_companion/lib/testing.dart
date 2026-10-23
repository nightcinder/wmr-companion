/// Test doubles for host apps and the facade's own tests.
///
/// `FakeTransport` replays a bridge without Bluetooth, and `FakeWmrBridge`
/// drives it with the firmware's FF11/FF12/FF14 streams. They are not part
/// of the stable runtime API, so they live in their own import.
library;

export 'package:wmr_core/ble/fake_transport.dart';
export 'package:wmr_core/ble/fake_wmr_bridge.dart';
