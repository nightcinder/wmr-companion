/// Android Bluetooth HID gamepad output for `wmr_companion` hosts.
///
/// The package is optional: a host that only needs in-process controller
/// input never imports it. On a platform without the Android plugin,
/// [HidGamepadTransport.status] reports [HidState.unsupported].
library;

export 'src/hid_gamepad_transport.dart';
export 'src/hid_report.dart';
