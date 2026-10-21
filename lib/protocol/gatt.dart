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

/// Client Characteristic Configuration descriptor. Write 0x0001 after every
/// connect; the bridge does not persist the subscription.
const String cccDescriptorUuid = '00002902-0000-1000-8000-00805f9b34fb';

/// ATT MTU to request after connecting (docs/ANDROID.md). The negotiated
/// value may be lower.
const int wmrRequestedMtu = 247;
