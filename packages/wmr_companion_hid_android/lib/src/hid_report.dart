/// HID gamepad report for the Bluetooth HID output stage.
///
/// Pure Dart. One input report with ID [hidReportId]; the ID is passed to
/// Android's `BluetoothHidDevice.sendReport` separately, so [encodeHidReport]
/// returns the payload only ([hidReportSize] bytes):
///
/// | byte | content |
/// |---|---|
/// | 0-1 | 16 button bits, little endian, Android/Linux HID slot order of [hidButtonOrder] (bit 0 first) |
/// | 2 | low nibble: hat switch 0..7 clockwise from up, 15 = centred; high nibble padding |
/// | 3, 4 | left stick X, Y: signed -127..127, Y positive down (HID convention) |
/// | 5, 6 | right stick X (Z), Y (Rz), same scale |
/// | 7, 8 | left trigger (Brake), right trigger (Accelerator): 0..255 |
///
/// The descriptor is a generic gamepad; how a host names the buttons depends
/// on the host (not checked on any). Not verified on hardware.
library;

import 'dart:typed_data';

import 'package:wmr_companion/wmr_companion.dart';

const int hidReportId = 1;
const int hidReportSize = 9;

/// Button bit order: bit 0 is the first entry. This is the Android/Linux HID
/// slot order, not the model order: slots 2 (C) and 5 (Z) are reserved and
/// stay clear because no WMR control uses them.
const List<GamepadButton?> hidButtonOrder = [
  GamepadButton.a,
  GamepadButton.b,
  null, // C
  GamepadButton.x,
  GamepadButton.y,
  null, // Z
  GamepadButton.l1,
  GamepadButton.r1,
  GamepadButton.l2,
  GamepadButton.r2,
  GamepadButton.select,
  GamepadButton.start,
  GamepadButton.guide,
  GamepadButton.l3,
  GamepadButton.r3,
];

/// Value of the hat nibble when no direction is pressed.
const int hidHatCentred = 15;

/// HID report descriptor matching [encodeHidReport].
final Uint8List hidReportDescriptor = Uint8List.fromList(const [
  0x05, 0x01, // Usage Page (Generic Desktop)
  0x09, 0x05, // Usage (Game Pad)
  0xA1, 0x01, // Collection (Application)
  0x85, hidReportId, //   Report ID
  // 16 buttons
  0x05, 0x09, //   Usage Page (Button)
  0x19, 0x01, //   Usage Minimum (1)
  0x29, 0x10, //   Usage Maximum (16)
  0x15, 0x00, //   Logical Minimum (0)
  0x25, 0x01, //   Logical Maximum (1)
  0x75, 0x01, //   Report Size (1)
  0x95, 0x10, //   Report Count (16)
  0x81, 0x02, //   Input (Data, Variable, Absolute)
  // Hat switch, 4 bits, null state outside 0..7
  0x05, 0x01, //   Usage Page (Generic Desktop)
  0x09, 0x39, //   Usage (Hat switch)
  0x15, 0x00, //   Logical Minimum (0)
  0x25, 0x07, //   Logical Maximum (7)
  0x35, 0x00, //   Physical Minimum (0)
  0x46, 0x3B, 0x01, //   Physical Maximum (315)
  0x65, 0x14, //   Unit (degrees)
  0x75, 0x04, //   Report Size (4)
  0x95, 0x01, //   Report Count (1)
  0x81, 0x42, //   Input (Data, Variable, Absolute, Null state)
  0x65, 0x00, //   Unit (none)
  0x75, 0x04, //   Report Size (4)
  0x95, 0x01, //   Report Count (1)
  0x81, 0x03, //   Input (Constant): padding
  // Sticks: X, Y, Z, Rz
  0x05, 0x01, //   Usage Page (Generic Desktop)
  0x09, 0x30, //   Usage (X)
  0x09, 0x31, //   Usage (Y)
  0x09, 0x32, //   Usage (Z)
  0x09, 0x35, //   Usage (Rz)
  0x15, 0x81, //   Logical Minimum (-127)
  0x25, 0x7F, //   Logical Maximum (127)
  0x75, 0x08, //   Report Size (8)
  0x95, 0x04, //   Report Count (4)
  0x81, 0x02, //   Input (Data, Variable, Absolute)
  // Triggers: Brake, Accelerator
  0x05, 0x02, //   Usage Page (Simulation Controls)
  0x09, 0xC5, //   Usage (Brake)
  0x09, 0xC4, //   Usage (Accelerator)
  0x15, 0x00, //   Logical Minimum (0)
  0x26, 0xFF, 0x00, //   Logical Maximum (255)
  0x75, 0x08, //   Report Size (8)
  0x95, 0x02, //   Report Count (2)
  0x81, 0x02, //   Input (Data, Variable, Absolute)
  0xC0, // End Collection
]);

/// Hat nibble for the d-pad buttons of [s]; opposite directions cancel.
int hidHat(GamepadState s) {
  final h =
      (s.pressed(GamepadButton.dpadRight) ? 1 : 0) -
      (s.pressed(GamepadButton.dpadLeft) ? 1 : 0);
  final v =
      (s.pressed(GamepadButton.dpadUp) ? 1 : 0) -
      (s.pressed(GamepadButton.dpadDown) ? 1 : 0);
  return switch ((h, v)) {
    (0, 1) => 0,
    (1, 1) => 1,
    (1, 0) => 2,
    (1, -1) => 3,
    (0, -1) => 4,
    (-1, -1) => 5,
    (-1, 0) => 6,
    (-1, 1) => 7,
    _ => hidHatCentred,
  };
}

int _axis(double v) => ((v.isFinite ? v : 0.0).clamp(-1.0, 1.0) * 127).round();

int _trigger(double v) =>
    ((v.isFinite ? v : 0.0).clamp(0.0, 1.0) * 255).round();

/// The report payload for [s]. The model has y positive up and HID has Y
/// positive down, so both stick Y values are negated here.
Uint8List encodeHidReport(GamepadState s) {
  var buttons = 0;
  for (var slot = 0; slot < hidButtonOrder.length; slot++) {
    final button = hidButtonOrder[slot];
    if (button != null && s.pressed(button)) buttons |= 1 << slot;
  }
  final out = Uint8List(hidReportSize);
  final d = ByteData.sublistView(out);
  d
    ..setUint16(0, buttons, Endian.little)
    ..setUint8(2, hidHat(s))
    ..setInt8(3, _axis(s.leftStick[0]))
    ..setInt8(4, -_axis(s.leftStick[1]))
    ..setInt8(5, _axis(s.rightStick[0]))
    ..setInt8(6, -_axis(s.rightStick[1]))
    ..setUint8(7, _trigger(s.leftTrigger))
    ..setUint8(8, _trigger(s.rightTrigger));
  return out;
}
