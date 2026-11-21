/// Monotonic marks of the link switches on one bridge route.
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
/// The top-level marks describe only the most recent episode: a later
/// switch overwrites them, and a retried dial overwrites the dial's start
/// mark, so the first attempt's start and the attempt count are kept beside
/// it. [LinkTimelineRecorder] also keeps an ordered
/// history of the last [LinkTimelineRecorder.episodeHistoryCapacity]
/// finished episodes, each with the same marks and the first record that
/// landed per lane after its failover, so a stall that a later switch
/// superseded stays readable. An episode's `last_tcp_record_us` is frozen
/// at the record that preceded its own stall; the top-level mark keeps
/// tracking the newest record the route delivered. The snapshot also
/// carries the live episode's frozen anchor as
/// `episode_last_tcp_record_us`, so a bundle taken after a later upgrade
/// still holds the anchor that episode's own figures need.
///
/// The composite is the only writer; hosts read the immutable
/// [LinkTimelineRecorder.snapshot] through
/// `CompositeBleTransport.linkTimelineFor`.
library;

/// The marks of one link switch, microseconds on the composite's clock.
///
/// A mark is null until its event has happened. Each episode resets its own
/// "first record" mark when it opens, so a later switch re-records it, and
/// the stall that opens one clears the marks of the episode it supersedes.
class LinkTimeline {
  const LinkTimeline({
    this.lastTcpRecordUs,
    this.stallDetectedUs,
    this.failoverBeginUs,
    this.failoverEndUs,
    this.firstBleRecordUs,
    this.upgradeDialStartUs,
    this.upgradeDialEndUs,
    this.firstUpgradeDialStartUs,
    this.upgradeDialAttempts = 0,
    this.firstTcpRecordUs,
    this.firstTcpRecordSession,
    this.firstTcpRecordWallUs,
    this.failoverOutcome,
    this.failoverReason,
    this.failoverCandidateCount,
    this.upgradeOutcome,
    this.upgradeCandidateCount,
  });

  /// Newest record delivered while the TCP leg carried the route. During a
  /// stall this is the last record before the link went silent; in a
  /// finished episode it is the record that preceded that episode's own
  /// stall.
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

  /// When this episode's first dial attempt started: a retried dial moves
  /// [upgradeDialStartUs] onto the newest attempt, so the one that opened
  /// the retries stays here.
  final int? firstUpgradeDialStartUs;

  /// How many dial attempts this episode has made; every start counts one,
  /// whether or not it finished.
  final int upgradeDialAttempts;

  /// First TCP record after the upgrade dial finished.
  final int? firstTcpRecordUs;

  /// The TCP session that delivered [firstTcpRecordUs], and the phone's wall
  /// clock in microseconds since the epoch sampled at that same record, so
  /// the stopwatch value can be placed on the wall clock.
  final String? firstTcpRecordSession;
  final int? firstTcpRecordWallUs;

  /// How the failover to BLE ended: `landed`, or `lost` with the reason the
  /// last BLE candidate failed (`no_candidate`, `connect_threw`,
  /// `activation_threw`), over [failoverCandidateCount] candidates.
  final String? failoverOutcome;
  final String? failoverReason;
  final int? failoverCandidateCount;

  /// How the latest upgrade attempt ended: `landed`, `no_candidate`,
  /// `dial_skipped`, `connect_threw`, `activation_threw` or `route_moved`,
  /// over [upgradeCandidateCount] TCP candidates.
  final String? upgradeOutcome;
  final int? upgradeCandidateCount;

  /// The marks under the keys the diagnostics bundle carries: one
  /// `<mark>_us` entry per mark field, null before the mark landed, plus
  /// the attempt count, the receipt anchor and the terminal outcomes.
  Map<String, Object?> toJson() => {
    'last_tcp_record_us': lastTcpRecordUs,
    'stall_detected_us': stallDetectedUs,
    'failover_begin_us': failoverBeginUs,
    'failover_end_us': failoverEndUs,
    'first_ble_record_us': firstBleRecordUs,
    'upgrade_dial_start_us': upgradeDialStartUs,
    'upgrade_dial_end_us': upgradeDialEndUs,
    'first_upgrade_dial_start_us': firstUpgradeDialStartUs,
    'upgrade_dial_attempts': upgradeDialAttempts,
    'first_tcp_record_us': firstTcpRecordUs,
    'first_tcp_record_session': firstTcpRecordSession,
    'first_tcp_record_wall_us': firstTcpRecordWallUs,
    'failover_outcome': failoverOutcome,
    'failover_reason': failoverReason,
    'failover_candidate_count': failoverCandidateCount,
    'upgrade_outcome': upgradeOutcome,
    'upgrade_candidate_count': upgradeCandidateCount,
  };
}

/// Records [LinkTimeline] marks as the composite moves a route between its
/// legs, keeping the last finished episodes beside the most recent one.
class LinkTimelineRecorder {
  /// How many finished episodes the history keeps; older ones drop.
  static const int episodeHistoryCapacity = 3;

  int? _lastTcpRecordUs;
  int? _stallDetectedUs;
  int? _failoverBeginUs;
  int? _failoverEndUs;
  int? _firstBleRecordUs;
  int? _upgradeDialStartUs;
  int? _upgradeDialEndUs;
  int? _firstTcpRecordUs;
  String? _firstTcpRecordSession;
  int? _firstTcpRecordWallUs;
  String? _failoverOutcome;
  String? _failoverReason;
  int? _failoverCandidateCount;
  String? _upgradeOutcome;
  int? _upgradeCandidateCount;

  /// The episode's first dial attempt's start, and how many attempts it
  /// has made: a retried dial overwrites only the latest-attempt marks.
  int? _firstUpgradeDialStartUs;
  int _upgradeDialAttempts = 0;

  /// The current episode's "last TCP record": the record that preceded its
  /// own stall, frozen when the episode opened. Records that arrive later
  /// move only the top-level mark, so the episode's stall gap stays the one
  /// it had while it was the most recent episode.
  int? _episodeLastTcpRecordUs;

  /// Finished episodes, oldest first, the last [episodeHistoryCapacity]
  /// kept.
  final List<LinkTimeline> _episodes = [];

  /// A TCP record arrived: it becomes the newest "last TCP record", and the
  /// first one after a finished upgrade dial opens that episode's "first
  /// TCP record".
  void onTcpRecord(int us, {String? session}) {
    _lastTcpRecordUs = us;
    if (_firstTcpRecordUs == null && _upgradeDialEndUs != null) {
      _firstTcpRecordUs = us;
      _firstTcpRecordSession = session;
      _firstTcpRecordWallUs = DateTime.now().microsecondsSinceEpoch;
    }
  }

  /// The watched TCP leg reported the link lost while it carried the route.
  ///
  /// The stall opens an episode. When the marks hold an episode that has
  /// begun, it is finished: freeze it into the history first, because a
  /// fresh detection immediately precedes the failover that supersedes it.
  void onStallDetected(int us) {
    if (_failoverBeginUs != null) _archiveEpisode();
    _resetEpisodeMarks();
    _episodeLastTcpRecordUs = _lastTcpRecordUs;
    _stallDetectedUs = us;
  }

  /// A failover to BLE took the route; the next BLE record opens the new
  /// episode's "first BLE record". One that follows a fresh stall finds its
  /// episode already opened and reset. One begun from a loss remembered
  /// while a switch held the route supersedes the episode the standing
  /// marks describe, so those marks go into the history first, and the
  /// stall they keep predates the records that followed it, which the
  /// reader rejects.
  void onFailoverBegin(int us) {
    if (_failoverBeginUs != null) {
      _archiveEpisode();
      _resetEpisodeMarks();
      _episodeLastTcpRecordUs = _lastTcpRecordUs;
    }
    _resetEpisodeMarks();
    _failoverBeginUs = us;
  }

  /// The failover landed: the route is active on BLE, over [candidates] BLE
  /// candidates.
  void onFailoverEnd(int us, {required int candidates}) {
    _failoverEndUs = us;
    _failoverOutcome = 'landed';
    _failoverReason = null;
    _failoverCandidateCount = candidates;
  }

  /// The failover found no BLE bridge that landed; [reason] names why the
  /// last candidate failed.
  void onFailoverLost({required int candidates, required String reason}) {
    _failoverOutcome = 'lost';
    _failoverReason = reason;
    _failoverCandidateCount = candidates;
  }

  /// A BLE record arrived. Only a route that failed over records one.
  void onBleRecord(int us) {
    if (_failoverBeginUs == null) return;
    _firstBleRecordUs ??= us;
  }

  /// A dial to TCP started (an upgrade probe, or a BLE-drop recovery); the
  /// next TCP record opens the new episode's "first TCP record". Every
  /// start is one attempt: the newest attempt owns the start mark, while
  /// the first attempt's start and the attempt count are kept beside it.
  void onUpgradeDialStart(int us) {
    _upgradeDialStartUs = us;
    _firstUpgradeDialStartUs ??= us;
    _upgradeDialAttempts++;
    _firstTcpRecordUs = null;
    _firstTcpRecordSession = null;
    _firstTcpRecordWallUs = null;
    _upgradeOutcome = null;
    _upgradeCandidateCount = null;
  }

  /// The upgrade dial finished, successfully or not.
  void onUpgradeDialEnd(int us) => _upgradeDialEndUs = us;

  /// How the latest upgrade attempt ended, over [candidates] TCP candidates.
  /// An attempt that never dialled (no candidate) records its outcome here
  /// without a dial start.
  void onUpgradeOutcome(String outcome, {required int candidates}) {
    _upgradeOutcome = outcome;
    _upgradeCandidateCount = candidates;
  }

  /// Clears the marks and the dial-attempt count an episode owns, so the
  /// episode that opens now starts its own. The stall stays: a fresh
  /// detection lands right after this, and one that predates the last TCP
  /// record belongs to a remembered loss, which the reader rejects. The
  /// top-level "last TCP record" stays because it tracks the newest
  /// record, not the episode's.
  void _resetEpisodeMarks() {
    _failoverBeginUs = null;
    _failoverEndUs = null;
    _firstBleRecordUs = null;
    _upgradeDialStartUs = null;
    _upgradeDialEndUs = null;
    _firstTcpRecordUs = null;
    _firstTcpRecordSession = null;
    _firstTcpRecordWallUs = null;
    _firstUpgradeDialStartUs = null;
    _upgradeDialAttempts = 0;
    _failoverOutcome = null;
    _failoverReason = null;
    _failoverCandidateCount = null;
    _upgradeOutcome = null;
    _upgradeCandidateCount = null;
  }

  /// Freezes the standing marks as one finished episode, oldest dropped
  /// once [episodeHistoryCapacity] are kept.
  void _archiveEpisode() {
    _episodes.add(
      LinkTimeline(
        lastTcpRecordUs: _episodeLastTcpRecordUs,
        stallDetectedUs: _stallDetectedUs,
        failoverBeginUs: _failoverBeginUs,
        failoverEndUs: _failoverEndUs,
        firstBleRecordUs: _firstBleRecordUs,
        upgradeDialStartUs: _upgradeDialStartUs,
        upgradeDialEndUs: _upgradeDialEndUs,
        firstUpgradeDialStartUs: _firstUpgradeDialStartUs,
        upgradeDialAttempts: _upgradeDialAttempts,
        firstTcpRecordUs: _firstTcpRecordUs,
        firstTcpRecordSession: _firstTcpRecordSession,
        firstTcpRecordWallUs: _firstTcpRecordWallUs,
        failoverOutcome: _failoverOutcome,
        failoverReason: _failoverReason,
        failoverCandidateCount: _failoverCandidateCount,
        upgradeOutcome: _upgradeOutcome,
        upgradeCandidateCount: _upgradeCandidateCount,
      ),
    );
    if (_episodes.length > episodeHistoryCapacity) {
      _episodes.removeAt(0);
    }
  }

  /// The marks so far, an immutable snapshot: the top-level marks of the
  /// most recent episode, its first dial attempt's start and its attempt
  /// count among them.
  LinkTimeline get timeline => LinkTimeline(
    lastTcpRecordUs: _lastTcpRecordUs,
    stallDetectedUs: _stallDetectedUs,
    failoverBeginUs: _failoverBeginUs,
    failoverEndUs: _failoverEndUs,
    firstBleRecordUs: _firstBleRecordUs,
    upgradeDialStartUs: _upgradeDialStartUs,
    upgradeDialEndUs: _upgradeDialEndUs,
    firstUpgradeDialStartUs: _firstUpgradeDialStartUs,
    upgradeDialAttempts: _upgradeDialAttempts,
    firstTcpRecordUs: _firstTcpRecordUs,
    firstTcpRecordSession: _firstTcpRecordSession,
    firstTcpRecordWallUs: _firstTcpRecordWallUs,
    failoverOutcome: _failoverOutcome,
    failoverReason: _failoverReason,
    failoverCandidateCount: _failoverCandidateCount,
    upgradeOutcome: _upgradeOutcome,
    upgradeCandidateCount: _upgradeCandidateCount,
  );

  /// The shape hosts read through `CompositeBleTransport.linkTimelineFor`:
  /// the top-level marks of the most recent episode ([LinkTimeline.toJson]
  /// names the keys), that episode's frozen anchor as
  /// `episode_last_tcp_record_us`, plus an `episodes` list carrying the
  /// same marks for each finished episode, oldest first.
  Map<String, Object?> get snapshot => {
    ...timeline.toJson(),
    'episode_last_tcp_record_us': _episodeLastTcpRecordUs,
    'episodes': [for (final episode in _episodes) episode.toJson()],
  };
}
