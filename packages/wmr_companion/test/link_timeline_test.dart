import 'package:test/test.dart';
import 'package:wmr_companion/testing.dart';

void main() {
  test('the first TCP record after a finished dial keeps its session and '
      'wall anchor', () {
    final recorder = LinkTimelineRecorder();
    recorder.onFailoverBegin(100);
    recorder.onFailoverEnd(200, candidates: 1);
    recorder.onUpgradeDialStart(300);
    recorder.onUpgradeDialEnd(400);

    recorder.onTcpRecord(500, wallUs: 9000, session: 'bridge-a');
    recorder.onTcpRecord(600, wallUs: 9100, session: 'bridge-b');

    final marks = recorder.snapshot;
    expect(marks['first_tcp_record_us'], 500);
    expect(marks['first_tcp_record_session'], 'bridge-a');
    expect(marks['first_tcp_record_wall_us'], 9000);
    expect(marks['last_tcp_record_us'], 600);
  });

  test('a finished episode archives its failover and upgrade outcomes', () {
    final recorder = LinkTimelineRecorder();
    recorder.onFailoverBegin(100);
    recorder.onFailoverLost(candidates: 2, reason: 'connect_threw');
    recorder.onUpgradeDialStart(300);
    recorder.onUpgradeOutcome('connect_threw', candidates: 2);

    recorder.onStallDetected(1000);

    final episodes = recorder.snapshot['episodes']! as List<Object?>;
    expect(episodes, hasLength(1));
    final archived = episodes.single! as Map<String, Object?>;
    expect(archived['failover_outcome'], 'lost');
    expect(archived['failover_reason'], 'connect_threw');
    expect(archived['failover_candidate_count'], 2);
    expect(archived['upgrade_outcome'], 'connect_threw');
    expect(archived['upgrade_candidate_count'], 2);
    expect(archived['upgrade_dial_attempts'], 1);

    final live = recorder.snapshot;
    expect(live['failover_outcome'], isNull);
    expect(live['failover_reason'], isNull);
    expect(live['upgrade_outcome'], isNull);
  });

  test('a new dial clears the previous attempt outcome and anchor', () {
    final recorder = LinkTimelineRecorder();
    recorder.onFailoverBegin(100);
    recorder.onFailoverEnd(200, candidates: 1);
    recorder.onUpgradeDialStart(300);
    recorder.onUpgradeDialEnd(400);
    recorder.onTcpRecord(500, wallUs: 9000, session: 'bridge-a');
    recorder.onUpgradeOutcome('landed', candidates: 1);

    recorder.onUpgradeDialStart(700);

    final marks = recorder.snapshot;
    expect(marks['upgrade_outcome'], isNull);
    expect(marks['upgrade_candidate_count'], isNull);
    expect(marks['first_tcp_record_session'], isNull);
    expect(marks['first_tcp_record_wall_us'], isNull);
    expect(marks['upgrade_dial_attempts'], 2);
  });

  test('a redial after a lost failover closes the episode with no attempt '
      'and no landing', () {
    final recorder = LinkTimelineRecorder();
    recorder.onStallDetected(90);
    recorder.onFailoverBegin(100);
    recorder.onFailoverLost(candidates: 0, reason: 'no_candidate');
    expect(recorder.awaitsRecovery, isTrue);

    recorder.onRecovery(900, lane: 'redial');
    recorder.onRecovery(950, lane: 'redial');

    final marks = recorder.snapshot;
    expect(marks['recovery_lane'], 'redial');
    expect(marks['recovery_us'], 900);
    expect(marks['upgrade_dial_attempts'], 0);
    expect(marks['failover_end_us'], isNull);
    expect(marks['first_tcp_record_us'], isNull);
    expect(recorder.awaitsRecovery, isFalse);
  });

  test('a recovery that also dialled counts that dial once', () {
    final recorder = LinkTimelineRecorder();
    recorder.onFailoverBegin(100);
    recorder.onFailoverLost(candidates: 1, reason: 'connect_threw');
    recorder.onUpgradeDialStart(300);
    recorder.onUpgradeDialEnd(400);
    recorder.onRecovery(500, lane: 'redial');

    final marks = recorder.snapshot;
    expect(marks['recovery_lane'], 'redial');
    expect(marks['upgrade_dial_attempts'], 1);
  });

  test('a landed failover does not await a recovery', () {
    final recorder = LinkTimelineRecorder();
    recorder.onFailoverBegin(100);
    recorder.onFailoverEnd(200, candidates: 1);
    expect(recorder.awaitsRecovery, isFalse);
  });
}
