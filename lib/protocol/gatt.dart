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

/// ATT MTU to request after connecting (docs/ANDROID.md). The negotiated
/// value may be lower.
const int wmrRequestedMtu = 247;
