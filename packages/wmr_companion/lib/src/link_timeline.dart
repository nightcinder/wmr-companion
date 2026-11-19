/// Monotonic marks of the most recent link switch on one bridge route.
///
/// [CompositeBleTransport] stamps every mark with its monotonic clock, so
/// the values are microseconds comparable only with each other and with
/// that clock's `nowUs`. Two episodes leave marks:
///
/// * A TCP stall and failover to BLE: the newest TCP record before the
///   stall, the moment the stalled leg was reported lost, the failover's
///   begin and end, and the first BLE record after the switch.
/// * A dial back to TCP while BLE carried — an upgrade probe, or the
///   recovery from a dropped BLE link: the dial's start and end, and the
///   first TCP record after the route moved.
///
/// The composite is the only writer; hosts read the immutable
/// [LinkTimelineRecorder.timeline] snapshot through
/// `CompositeBleTransport.linkTimelineFor`.
library;

/// The marks of one link switch, microseconds on the composite's clock.
///
/// A mark is null until its event has happened. Each episode resets its own
/// "first record" mark when it begins, so a later switch re-records it, and
/// a failover's begin clears the marks of the episode it supersedes.
class LinkTimeline {
  const LinkTimeline({
    this.lastTcpRecordUs,
    this.stallDetectedUs,
    this.failoverBeginUs,
    this.failoverEndUs,
    this.firstBleRecordUs,
    this.upgradeDialStartUs,
    this.upgradeDialEndUs,
    this.firstTcpRecordUs,
  });

  /// Newest record delivered while the TCP leg carried the route. During a
  /// stall this is the last record before the link went silent.
  final int? lastTcpRecordUs;

  /// When the watched TCP leg was reported lost while it carried the route,
  /// as the liveness probe catches a silent socket.
  final int? stallDetectedUs;

  /// When a failover to BLE took over the route, and when the route became
  /// active on BLE.
  final int? failoverBeginUs;
  final int? failoverEndUs;

  /// First BLE record after the failover began.
  final int? firstBleRecordUs;

  /// When a dial to TCP started — an upgrade probe, or the recovery from a
  /// dropped BLE link — and when that dial finished (successfully or not).
  final int? upgradeDialStartUs;
  final int? upgradeDialEndUs;

  /// First TCP record after the upgrade dial finished.
  final int? firstTcpRecordUs;

  /// The marks under the keys the diagnostics bundle carries: one
  /// `<mark>_us` entry per field, null before the mark landed.
  Map<String, Object?> toJson() => {
    'last_tcp_record_us': lastTcpRecordUs,
    'stall_detected_us': stallDetectedUs,
    'failover_begin_us': failoverBeginUs,
    'failover_end_us': failoverEndUs,
    'first_ble_record_us': firstBleRecordUs,
    'upgrade_dial_start_us': upgradeDialStartUs,
    'upgrade_dial_end_us': upgradeDialEndUs,
    'first_tcp_record_us': firstTcpRecordUs,
  };
}

/// Records [LinkTimeline] marks as the composite moves a route between its
/// legs.
class LinkTimelineRecorder {
  int? _lastTcpRecordUs;
  int? _stallDetectedUs;
  int? _failoverBeginUs;
  int? _failoverEndUs;
  int? _firstBleRecordUs;
  int? _upgradeDialStartUs;
  int? _upgradeDialEndUs;
  int? _firstTcpRecordUs;

  /// A TCP record arrived: it becomes the newest "last TCP record", and the
  /// first one after a finished upgrade dial opens that episode's "first
  /// TCP record".
  void onTcpRecord(int us) {
    _lastTcpRecordUs = us;
    if (_firstTcpRecordUs == null && _upgradeDialEndUs != null) {
      _firstTcpRecordUs = us;
    }
  }

  /// The watched TCP leg reported the link lost while it carried the route.
  void onStallDetected(int us) => _stallDetectedUs = us;

  /// A failover to BLE took the route; the next BLE record opens the new
  /// episode's "first BLE record". The marks of the episode this failover
  /// supersedes go with it: that failover's end until this one lands, and
  /// any dial it left behind. The stall mark stays: a fresh detection
  /// immediately precedes the begin, and one that predates the last TCP
  /// record belongs to a remembered loss, which the reader rejects.
  void onFailoverBegin(int us) {
    _failoverBeginUs = us;
    _failoverEndUs = null;
    _firstBleRecordUs = null;
    _upgradeDialStartUs = null;
    _upgradeDialEndUs = null;
    _firstTcpRecordUs = null;
  }

  /// The failover landed: the route is active on BLE.
  void onFailoverEnd(int us) => _failoverEndUs = us;

  /// A BLE record arrived. Only a route that failed over records one.
  void onBleRecord(int us) {
    if (_failoverBeginUs == null) return;
    _firstBleRecordUs ??= us;
  }

  /// A dial to TCP started (an upgrade probe, or a BLE-drop recovery); the
  /// next TCP record opens the new episode's "first TCP record".
  void onUpgradeDialStart(int us) {
    _upgradeDialStartUs = us;
    _firstTcpRecordUs = null;
  }

  /// The upgrade dial finished, successfully or not.
  void onUpgradeDialEnd(int us) => _upgradeDialEndUs = us;

  /// The marks so far, an immutable snapshot.
  LinkTimeline get timeline => LinkTimeline(
    lastTcpRecordUs: _lastTcpRecordUs,
    stallDetectedUs: _stallDetectedUs,
    failoverBeginUs: _failoverBeginUs,
    failoverEndUs: _failoverEndUs,
    firstBleRecordUs: _firstBleRecordUs,
    upgradeDialStartUs: _upgradeDialStartUs,
    upgradeDialEndUs: _upgradeDialEndUs,
    firstTcpRecordUs: _firstTcpRecordUs,
  );
}
