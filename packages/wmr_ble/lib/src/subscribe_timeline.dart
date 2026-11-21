/// The GATT subscribe marks of one bridge, microseconds on the BLE
/// transport's monotonic clock.
///
/// [UniversalBleTransport] records them as a dial runs: when the GATT
/// connect began, when service discovery finished, when the FF14 CCCD
/// write landed, the first FF14 notification that followed it, and every
/// disconnect. The adapter's radio off/on is stamped beside them by the
/// transport, because one radio serves every bridge. A new dial re-records
/// its own steps, so the marks describe the most recent episode; a mark
/// that has not landed reads null.
///
/// The values are comparable only with each other and with that clock's
/// `nowUs`; never with the bridge's timestamps or another transport's
/// clock. Two marks the sequence records without yielding in between can
/// share a microsecond, so a reader asserts order, not strict growth.
library;

/// Records the marks of one device's GATT dials, as
/// [UniversalBleTransport] drives them.
class SubscribeTimeline {
  int? _gattConnectStartUs;
  int? _serviceDiscoveryDoneUs;
  int? _ff14CccdWriteUs;
  int? _firstFf14NotificationUs;
  int? _disconnectUs;

  /// A GATT dial began. The first-notification mark of the episode before
  /// it is cleared: the notification that will open this dial's mark has
  /// not arrived yet.
  void onGattConnectStart(int us) {
    _gattConnectStartUs = us;
    _firstFf14NotificationUs = null;
  }

  /// Service discovery finished on this dial.
  void onServiceDiscoveryDone(int us) => _serviceDiscoveryDoneUs = us;

  /// The FF14 CCCD write landed. The first FF14 notification after it
  /// opens this dial's first-notification mark, so the one the previous
  /// subscription recorded is cleared.
  void onFf14CccdWrite(int us) {
    _ff14CccdWriteUs = us;
    _firstFf14NotificationUs = null;
  }

  /// The first FF14 notification after the latest CCCD write. Later
  /// notifications do not move it.
  void onFirstFf14Notification(int us) => _firstFf14NotificationUs ??= us;

  /// The device's link went down — a reported loss, a local disconnect, or
  /// the radio turning off under it.
  void onDisconnect(int us) => _disconnectUs = us;

  /// The marks under the keys the diagnostics bundle carries: one
  /// `<mark>_us` entry per mark, null before the mark landed.
  Map<String, Object?> toJson() => {
    'gatt_connect_start_us': _gattConnectStartUs,
    'service_discovery_done_us': _serviceDiscoveryDoneUs,
    'ff14_cccd_write_us': _ff14CccdWriteUs,
    'first_ff14_notification_us': _firstFf14NotificationUs,
    'disconnect_us': _disconnectUs,
  };
}
