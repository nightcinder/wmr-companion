/// Test doubles for hosts and this package's own tests.
///
/// `FakeBleAdapter` implements [BleAdapter] without a platform channel, so a
/// host can exercise `UniversalBleTransport` (or its own adapter-level code)
/// on the host without a phone.
library;

export 'src/fake_adapter.dart';
