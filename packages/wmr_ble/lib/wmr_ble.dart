/// `universal_ble` transport for the WMR Bridge.
///
/// Android and iOS are both v1 targets. The package owns the platform seam
/// ([BleAdapter]) and the connection sequence ([UniversalBleTransport]); the
/// protocol and facade live in `wmr_core` and `wmr_companion`.
library;

export 'src/ble_adapter.dart';
export 'src/universal_ble_adapter.dart';
export 'src/universal_ble_transport.dart';
