import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wmr_core/protocol/echo.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/echo_client.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_core/services/latency_recorder.dart';

EchoSample _echo(int id, {required int t1, int rtt = 8000, int queue = 0}) =>
    EchoSample(
      t1Us: t1,
      t1DoneUs: t1 + 200,
      t4Us: t1 + rtt + 300,
      answer: EchoAnswer(
        pingId: id,
        rxTimeUs: 9000000 + id * 1000,
        turnaroundUs: 300,
        queueDepth: queue,
      ),
    );

LatencyRecorder _recorder({int maxRows = 250000}) => LatencyRecorder(
  started: DateTime(2026, 10, 22, 13, 5, 9),
  originUs: 1000000,
  stream: 'decoded',
  maxRows: maxRows,
);

void main() {
  group('UsPercentiles', () {
    test('nearest rank over sorted values', () {
      final p = UsPercentiles.of([for (var i = 100; i >= 1; i--) i * 10]);
      expect(p.count, 100);
      expect(p.min, 10);
      expect(p.p50, 510); // index round(0.5 * 99) = 50
      expect(p.p95, 950);
      expect(p.p90, 900);
      expect(p.p99, 990);
      expect(p.max, 1000);
    });

    test('empty is all zero', () {
      expect(UsPercentiles.of(const []).count, 0);
    });
  });

  group('raw frames', () {
    test('inter-arrival, stalls, sequence gaps and out of order', () {
      final r = _recorder();
      var t = 1000000;
      r.addFrame(wmrHandLeft, 1, t);
      r.addFrame(wmrHandLeft, 2, t += 5000);
      r.addFrame(wmrHandLeft, 4, t += 5000); // one gap
      r.addFrame(wmrHandLeft, 5, t += 60000); // a stall
      r.addFrame(wmrHandLeft, 5, t += 5000); // duplicate
      final rep = r.report(nowUs: t);
      final left = rep.hands[wmrHandLeft];
      expect(left.records, 5);
      expect(left.arrivals, 5);
      expect(left.spanUs, 75000);
      expect(left.interArrival.count, 4);
      expect(left.interArrival.p50, 5000);
      expect(left.interArrival.max, 60000);
      expect(left.stalls, 1);
      expect(left.sequenceGaps, 1);
      expect(left.outOfOrder, 1);
      expect(left.sequenceLoss, closeTo(1 / 6, 1e-9));
      expect(left.missingFromTicks, isNull);
      expect(left.delay, isNull);
      expect(rep.hands[wmrHandRight].records, 0);
      expect(rep.durationUs, t - 1000000);
    });

    test('sequence numbers compare across the u32 wrap', () {
      final r = _recorder();
      r.addFrame(wmrHandRight, 0xffffffff, 1000000);
      r.addFrame(wmrHandRight, 1, 1005000);
      final right = r.report(nowUs: 1005000).hands[wmrHandRight];
      expect(right.sequenceGaps, 1);
      expect(right.outOfOrder, 0);
    });
  });

  group('decoded records', () {
    test('missing reports from the controller ticks', () {
      final r = _recorder();
      var ticks = 0;
      var rx = 500;
      var t = 1000000;
      for (var seq = 1; seq <= 40; seq++) {
        // Report 20 never reaches the ESP32: ticks jump, sequence does not.
        final step = seq == 21 ? 2 : 1;
        if (seq > 1) {
          ticks += 50000 * step;
          rx += 5000 * step;
          t += 5000 * step;
        }
        r.addRecord(wmrHandLeft, seq, t, deviceTicks: ticks, espRxUs: rx);
      }
      final left = r.report(nowUs: t).hands[wmrHandLeft];
      expect(left.records, 40);
      expect(left.sequenceGaps, 0);
      expect(left.missingFromTicks, 1);
      expect(left.periodUs, 5000);
      expect(left.tickLoss, closeTo(1 / 41, 1e-9));
    });

    test('records in one notification count as one arrival', () {
      final r = _recorder();
      var seq = 0;
      var ticks = 0;
      for (final t in [1000000, 1015000]) {
        for (var i = 0; i < 3; i++) {
          seq++;
          ticks += 50000;
          r.addRecord(
            wmrHandRight,
            seq,
            t,
            deviceTicks: ticks,
            espRxUs: ticks ~/ 10,
          );
        }
      }
      final right = r.report(nowUs: 1015000).hands[wmrHandRight];
      expect(right.records, 6);
      expect(right.arrivals, 2);
      expect(right.interArrival.count, 1);
      expect(right.interArrival.p50, 15000);
      expect(r.rows.map((x) => x.interArrivalUs), [null, 0, 0, 15000, 0, 0]);
    });

    test('delay above the window minimum and delay variation', () {
      final r = _recorder();
      // Phone clock = ESP32 clock + 7 s (unknown in practice) + extra delay.
      const extra = [0, 2000, 0, 5000, 1000];
      for (var i = 0; i < extra.length; i++) {
        final rx = 3000000 + i * 5000;
        r.addRecord(
          wmrHandLeft,
          i + 1,
          rx + 7000000 + extra[i],
          deviceTicks: i * 50000,
          espRxUs: rx,
        );
      }
      final left = r.report(nowUs: 20000000).hands[wmrHandLeft];
      expect(left.delay!.count, 5);
      expect(left.delay!.p50, 1000);
      expect(left.delay!.max, 5000);
      expect(left.delayVariation!.count, 4);
      expect(left.delayVariation!.max, 5000);
      expect(left.delayVariation!.p50, 4000); // of 2000, 2000, 4000, 5000
    });

    test('each 10 s window has its own minimum, so drift does not add up', () {
      final r = _recorder();
      // The phone clock runs 100 ppm fast: 2 ms over 20 s.
      var seq = 0;
      for (var us = 0; us < 20000000; us += 5000) {
        seq++;
        r.addRecord(
          wmrHandLeft,
          seq,
          1000000 + us + us ~/ 10000,
          deviceTicks: us * 10,
          espRxUs: us,
        );
      }
      final left = r.report(nowUs: 21000000).hands[wmrHandLeft];
      // Within one window drift reaches 1 ms, never 2 ms.
      expect(left.delay!.max, lessThanOrEqualTo(1000));
    });
  });

  group('export', () {
    test('CSV header and rows', () {
      final r = _recorder();
      r.addFrame(wmrHandLeft, 7, 1002000, bridgeId: 'bridge-l');
      r.addRecord(
        wmrHandRight,
        3,
        1003000,
        deviceTicks: 123,
        espRxUs: 456,
        bridgeId: 'bridge-r',
      );
      expect(r.toCsv().split('\n'), [
        'hand,bridge_id,sequence,arrival_us,inter_arrival_us,seq_delta,'
            'device_ticks,device_dt_us,esp_rx_us',
        'LEFT,bridge-l,7,2000,,,,,',
        'RIGHT,bridge-r,3,3000,,,123,,456',
        '',
      ]);
    });

    test('rows over the limit are counted, not kept', () {
      final r = _recorder(maxRows: 2);
      for (var i = 1; i <= 5; i++) {
        r.addFrame(wmrHandLeft, i, 1000000 + i * 5000);
      }
      final rep = r.report(nowUs: 1030000);
      expect(r.rows, hasLength(2));
      expect(rep.rowsDropped, 3);
      expect(rep.hands[wmrHandLeft].records, 5);
    });

    test('JSON summary', () {
      final r = _recorder()..markModeChanged();
      r.addFrame(wmrHandLeft, 1, 1000000, bridgeId: 'bridge-l');
      r.addFrame(wmrHandLeft, 3, 1005000, bridgeId: 'bridge-l');
      final rep = r.report(
        nowUs: 3000000,
        links: {
          'bridge-l': const LatencyLink(
            mtu: 517,
            rssiStart: -60,
            priorityRequested: true,
          ).withEnd(rssiEnd: -62),
        },
        counters: const {'incomplete_frames': 2},
      );
      final json = jsonDecode(rep.toJsonString()) as Map<String, Object?>;
      expect(json['format'], 'wmr-latency');
      expect(json['version'], 3);
      expect(json['stream'], 'decoded');
      expect(json['duration_us'], 2000000);
      expect(json['mode_changed'], true);
      expect(json['round_trip'], {
        'measured': false,
        'reason': 'echo not used (needs the FF15 echo, WMR_Bridge #13)',
      });
      expect(json['counters'], {'incomplete_frames': 2});
      expect(json['link'], {
        'bridge-l': {
          'mtu': 517,
          'rssi_start_dbm': -60,
          'rssi_end_dbm': -62,
          'connection_interval_us': null,
          'phy': null,
          'high_priority_requested': true,
        },
      });
      final hands = json['hands'] as List<Object?>;
      final left = hands.first as Map<String, Object?>;
      expect(left['hand'], 'LEFT');
      expect(left['bridge_id'], 'bridge-l');
      expect(left['bridge_records'], {'bridge-l': 2});
      expect(left['records'], 2);
      expect(left['sequence_gaps'], 1);
      expect(left['sequence_loss'], 0.3333);
      expect((left['inter_arrival'] as Map)['p50_us'], 5000);
      expect(left['missing_from_ticks'], isNull);
    });

    test('LatencyStore saves both files and lists them newest first', () async {
      final dir = Directory.systemTemp.createTempSync('latency_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = LatencyStore(Directory('${dir.path}/latency'));
      expect(store.list(), isEmpty);
      final r = _recorder()..addFrame(wmrHandLeft, 1, 1000000);
      final saved = await store.save(r, r.report(nowUs: 2000000));
      expect(saved.name, 'latency-20261022-130509');
      expect(File(saved.csvPath).readAsStringSync(), startsWith('hand,'));
      expect(File(saved.jsonPath).readAsStringSync(), contains('wmr-latency'));
      // A stray file and a CSV without its JSON are not listed.
      File('${dir.path}/latency/notes.txt').writeAsStringSync('x');
      File('${dir.path}/latency/latency-20261022-120000.csv')
          .writeAsStringSync('x');
      expect(store.list().map((s) => s.name), ['latency-20261022-130509']);
    });
  });

  group('round trip', () {
    test('summary, JSON and echo CSV', () {
      final r = _recorder();
      r.addEcho(_echo(1, t1: 1100000, rtt: 6000));
      r.addEcho(_echo(2, t1: 1350000, rtt: 8000, queue: 3));
      r.addEcho(_echo(3, t1: 1600000, rtt: 20000));
      r.addEchoTimeout();
      r.addEchoFailure();
      final rep = r.report(
        nowUs: 2000000,
        echoCounters: const {'late_or_duplicate_answers': 1},
      );
      final e = rep.echo!;
      expect(e.answered, 3);
      expect(e.sent, 5);
      expect(e.timeouts, 1);
      expect(e.failedWrites, 1);
      expect(e.rtt.min, 6000);
      expect(e.rtt.p50, 8000);
      expect(e.rtt.p95, 20000);
      expect(e.rtt.max, 20000);
      expect(e.endToEnd.max, 20300);
      expect(e.turnaround.p50, 300);
      expect(e.maxQueueDepth, 3);

      final json = jsonDecode(rep.toJsonString()) as Map<String, Object?>;
      final rt = json['round_trip'] as Map<String, Object?>;
      expect(rt['measured'], true);
      expect(rt['source'], 'FF15 echo');
      expect(rt['sent'], 5);
      expect((rt['rtt'] as Map)['p50_us'], 8000);
      expect(rt['counters'], {'late_or_duplicate_answers': 1});

      final lines = r.toEchoCsv().split('\n');
      expect(
        lines.first,
        'ping_id,t1_us,t1_done_us,t4_us,end_to_end_us,esp_rx_us,'
        'turnaround_us,rtt_us,queue_depth,clock_offset_us',
      );
      // Phone times are relative to the run start (1000000).
      expect(lines[1].split(',').take(9).toList(), [
        '1',
        '100000',
        '100200',
        '106300',
        '6300',
        '9001000',
        '300',
        '6000',
        '0',
      ]);
      expect(lines, hasLength(5)); // header, 3 rows, trailing newline
    });

    test('without echo the report says it was not measured', () {
      final r = _recorder()..addFrame(wmrHandLeft, 1, 1000000);
      expect(r.echoUsed, isFalse);
      expect(r.report(nowUs: 2000000).echo, isNull);
    });

    test('all pings timing out still gives a round-trip section', () {
      final r = _recorder()..useEcho();
      r.addEchoTimeout();
      final e = r.report(nowUs: 2000000).echo!;
      expect(e.answered, 0);
      expect(e.timeouts, 1);
      expect(e.rtt.count, 0);
    });

    test('store writes the echo CSV only for runs that used echo', () async {
      final dir = Directory.systemTemp.createTempSync('latency_echo');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = LatencyStore(Directory('${dir.path}/latency'));
      final plain = _recorder()..addFrame(wmrHandLeft, 1, 1000000);
      final a = await store.save(plain, plain.report(nowUs: 2000000));
      expect(a.echoCsvPath, isNull);
      expect(a.paths, [a.csvPath, a.jsonPath]);

      final withEcho = LatencyRecorder(
        started: DateTime(2026, 10, 22, 14),
        originUs: 1000000,
        stream: 'decoded',
      )..addEcho(_echo(1, t1: 1100000));
      final b = await store.save(withEcho, withEcho.report(nowUs: 2000000));
      expect(b.echoCsvPath, endsWith('latency-20261022-140000-echo.csv'));
      expect(File(b.echoCsvPath!).readAsStringSync(), startsWith('ping_id,'));

      final listed = store.list();
      expect(listed.map((r) => r.name), [
        'latency-20261022-140000',
        'latency-20261022-130509',
      ]);
      expect(listed.first.echoCsvPath, b.echoCsvPath);
      expect(listed.last.echoCsvPath, isNull);
    });
  });
}
