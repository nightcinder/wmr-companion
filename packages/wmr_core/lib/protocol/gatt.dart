/// GATT identifiers of the WMR Bridge firmware.
///
/// Source of truth: WMR_Bridge `wmr_bridge.gatt` and `docs/PROTOCOL.md`.
/// The FF10/FF11 UUIDs are experimental, not assigned for production use.
library;

const String wmrBridgeDeviceName = 'WMR Bridge';

/// Primary service, advertised as the 16-bit UUID 0xFF10.
const String wmrBridgeServiceUuid = '0000ff10-0000-1000-8000-00805f9b34fb';

/// Read returns a 16-byte status value; notify carries frame fragments.
const String wmrBridgeStreamCharUuid = '0000ff11-0000-1000-8000-00805f9b34fb';

/// Decoded stream: one 56-byte record per notification, notify only. Mutually
/// exclusive with [wmrBridgeStreamCharUuid]: enabling one while the other is
/// enabled fails with ATT error [attErrorOtherStreamActive]. Firmware side
/// merged but not run on hardware (docs/PROTOCOL.md, "FF12 decoded stream").
const String wmrBridgeDecodedCharUuid = '0000ff12-0000-1000-8000-00805f9b34fb';

/// Batched decoded stream: a 2-byte header and 1 to 9 FF12 records per
/// notification, notify only (docs/PROTOCOL.md, "FF14"). FF11, FF12 and FF14
/// are mutually exclusive in every order. Firmware merged (`8f5921a`), not
/// run on hardware.
const String wmrBridgeBatchedCharUuid = '0000ff14-0000-1000-8000-00805f9b34fb';

/// Echo characteristic for BLE round-trip time: write without response (4-byte
/// ping) and notify (20-byte answer). Independent of the FF11/FF12/FF14
/// exclusion. Firmware merged (WMR_Bridge #13, docs/PROTOCOL.md "Echo, FF15"),
/// not run on hardware.
const String wmrBridgeEchoCharUuid = '0000ff15-0000-1000-8000-00805f9b34fb';

/// Controller config block (calibration): write a 5-byte cursor (hand, offset),
/// read a 16-byte header plus up to 496 data bytes, notify carries the header
/// when a hand's state changes. Independent of the stream exclusion. Layout
/// approved 2026-10-22; firmware merged (WMR_Bridge #17), reads of both
/// controllers' block reported working (user-reported). docs/PROTOCOL.md
/// "Controller config block, FF13".
const String wmrBridgeConfigCharUuid = '0000ff13-0000-1000-8000-00805f9b34fb';

/// Firmware version: read-only UTF-8 string with no terminator, at most 31
/// bytes, carrying the ESP-IDF `PROJECT_VER` value (WMR_Bridge #38 and later).
/// The build tooling writes the same string to `manifest.json` and
/// `build-info.json`. Independent of the stream exclusion and of FF13/FF15.
const String wmrBridgeVersionCharUuid = '0000ff16-0000-1000-8000-00805f9b34fb';

/// Controller control and status v2: write a 1-2 byte command (discover,
/// connect, disconnect, forget addresses, forget bond), read or subscribe to
/// a 20-byte status. Independent of the FF11/FF12/FF14 exclusion. Firmware
/// merged in WMR_Bridge #70 (v0.1.1), not run on hardware. docs/PROTOCOL.md
/// "Controller scan and status v2, FF17".
const String wmrBridgeControllerCharUuid =
    '0000ff17-0000-1000-8000-00805f9b34fb';

/// ATT application error the bridge returns when a CCC write would enable a
/// second stream. Write 0x0000 to the active CCC first.
const int attErrorOtherStreamActive = 0x80;

/// Smallest ATT MTU that carries one FF12 record (56 + 3 bytes of ATT opcode
/// and handle). Below it the bridge sends nothing on FF12.
const int wmrDecodedMinMtu = 59;

/// Smallest ATT MTU that carries one FF14 batch of one record (3 + 2 + 56).
/// Below it the bridge sends nothing on FF14. An MTU of 59 or 60 works for
/// FF12 and not for FF14.
const int wmrBatchedMinMtu = 61;

/// Client Characteristic Configuration descriptor. Write 0x0001 after every
/// connect; the bridge does not persist the subscription.
const String cccDescriptorUuid = '00002902-0000-1000-8000-00805f9b34fb';

/// ATT MTU to request after connecting (docs/ANDROID.md): 517 is the largest
/// ATT MTU, and with it an FF14 batch holds up to 9 records. The negotiated
/// value may be lower; the app uses what the stack reports.
const int wmrRequestedMtu = 517;
