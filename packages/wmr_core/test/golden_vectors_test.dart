// Shared golden vectors: the app's parsers and TickTimer against
// test/fixtures/wmr_golden_v1.json.
//
// The same file is committed in WMR_Bridge as tests/vectors/wmr_golden_v1.json
// and checked there by pi/tests/test_golden_vectors.py against the Pi decoder,
// so bridge and app are pinned to identical bytes. Field reference:
// test/fixtures/README_golden.md.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wmr_core/domain/tick_timer.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/echo.dart';

typedef Json = Map<String, dynamic>;

Uint8List unhex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<Json> objects(Object? list) =>
    (list as List<dynamic>).map((e) => e as Json).toList();

List<int> ints(Object? list) =>
    (list as List<dynamic>).map((e) => e as int).toList();

List<double> doubles(Object? list) =>
    (list as List<dynamic>).map((e) => (e as num).toDouble()).toList();

List<String> strings(Object? list) =>
    (list as List<dynamic>).map((e) => e as String).toList();

void main() {
  final golden = jsonDecode(
    File('test/fixtures/wmr_golden_v1.json').readAsStringSync(),
  ) as Json;
  final frames = objects(golden['ff11_frames']);

  test('file header and coverage', () {
    expect(golden['format'], 'wmr-golden');
    expect(golden['version'], 1);
    expect(frames.length, greaterThanOrEqualTo(12));
  });

  group('FF12 records', () {
    for (final c in frames) {
      test('${c['name']}: parse and re-encode', () {
        final wire = unhex(c['record_hex'] as String);
        expect(wire.length, wmrDecodedSize);
        final result = parseDecodedRecord(wire);
        expect(result.error, isNull);
        final r = result.record!;
        final want = c['record'] as Json;

        expect(wire[0], want['version']);
        expect(r.hand, want['hand']);
        expect(r.hand, c['hand']);
        expect(r.flags, want['flags']);
        expect(r.calibrated, isFalse);
        expect(r.buttons, want['buttons']);
        expect(r.sequence, want['sequence']);
        expect(r.sequence, c['sequence']);
        expect(r.rxTimeUs, want['rx_time_us']);
        expect(r.rxTimeUs, c['rx_time_us']);
        expect(r.deviceTicks, want['device_ticks']);
        // Exact: the JSON numbers are binary32 values widened to binary64.
        expect(r.gyro, doubles(want['gyro']));
        expect(r.accel, doubles(want['accel']));
        final gyroHex = strings(want['gyro_f32_hex']);
        final accelHex = strings(want['accel_f32_hex']);
        for (var i = 0; i < 3; i++) {
          expect(hexOf(wire.sublist(20 + 4 * i, 24 + 4 * i)), gyroHex[i]);
          expect(hexOf(wire.sublist(32 + 4 * i, 36 + 4 * i)), accelHex[i]);
        }
        expect(r.temperatureRaw, want['temperature_raw']);
        expect(r.stick, ints(want['stick']));
        expect(r.trackpad, ints(want['trackpad']));
        expect(r.trigger, want['trigger']);
        expect(r.battery, want['battery']);

        expect(hexOf(encodeDecodedRecord(r)), c['record_hex']);
      });
    }

    test('the decoded state agrees with the record fields', () {
      for (final c in frames) {
        final state = c['state'] as Json;
        final want = c['record'] as Json;
        expect(want['buttons'], state['buttons'], reason: '${c['name']}');
        expect(want['device_ticks'], state['ticks'], reason: '${c['name']}');
        expect(want['battery'], state['battery'], reason: '${c['name']}');
      }
    });

    for (final c in objects(golden['ff12_invalid_records'])) {
      test('rejects ${c['name']}', () {
        final result = parseDecodedRecord(unhex(c['hex'] as String));
        expect(result.record, isNull);
        expect(result.error!.name, c['dart_error']);
      });
    }
  });

  group('FF14 batch', () {
    final spec = golden['ff14_batch'] as Json;
    final indices = ints(spec['record_indices']);

    test('parses into the listed records', () {
      final value = unhex(spec['batch_hex'] as String);
      expect(value.length, spec['length']);
      expect(value[0], wmrBatchVersion);
      expect(value[0], spec['version']);
      expect(value[1], spec['count']);
      final result = parseDecodedBatch(value);
      expect(result.error, isNull);
      final records = result.records!;
      expect(records.length, spec['count']);
      for (var i = 0; i < records.length; i++) {
        final c = frames[indices[i]];
        final r = records[i].record!;
        expect(hexOf(encodeDecodedRecord(r)), c['record_hex']);
        expect(r.hand, c['hand']);
        expect(r.sequence, c['sequence']);
        expect(r.rxTimeUs, c['rx_time_us']);
      }
    });

    test('encodes to the same bytes', () {
      final records = [
        for (final i in indices) unhex(frames[i]['record_hex'] as String),
      ];
      expect(hexOf(encodeDecodedBatch(records)), spec['batch_hex']);
    });

    for (final c in objects(spec['invalid'])) {
      test('rejects ${c['name']}', () {
        final result = parseDecodedBatch(unhex(c['hex'] as String));
        expect(result.records, isNull);
        expect(result.error!.name, c['dart_error']);
      });
    }
  });

  group('FF15 echo', () {
    final spec = golden['ff15_echo'] as Json;

    test('sizes', () {
      expect(wmrEchoRequestSize, spec['request_size']);
      expect(wmrEchoAnswerSize, spec['answer_size']);
    });

    for (final c in objects(spec['examples'])) {
      test('${c['name']}: request and answer', () {
        final pingId = c['ping_id'] as int;
        expect(hexOf(encodeEchoRequest(pingId)), c['request_hex']);
        final result = parseEchoAnswer(unhex(c['answer_hex'] as String));
        expect(result.error, isNull);
        final a = result.answer!;
        expect(a.pingId, pingId);
        expect(a.rxTimeUs, c['rx_time_us']);
        expect(a.turnaroundUs, c['turnaround_us']);
        expect(a.queueDepth, c['queue_depth']);
        expect(hexOf(encodeEchoAnswer(a)), c['answer_hex']);
      });
    }

    for (final c in objects(spec['invalid_answers'])) {
      test('rejects ${c['name']}', () {
        final result = parseEchoAnswer(unhex(c['hex'] as String));
        expect(result.answer, isNull);
        expect(result.error!.name, c['dart_error']);
      });
    }
  });

  group('timing', () {
    final timing = golden['timing'] as Json;

    test('constants match TickTimer defaults', () {
      final t = TickTimer();
      expect(wmrTickNanoseconds, timing['tick_ns']);
      expect(
        t.discontinuityTolerance.inMicroseconds,
        timing['discontinuity_tolerance_us'],
      );
      expect(t.maxDeltaTicks, timing['max_delta_ticks']);
      expect(t.window, timing['window']);
      expect(t.warmup, timing['warmup']);
      expect(t.refresh, timing['refresh']);
    });

    for (final s in objects(timing['sequences'])) {
      test('${s['name']}: steps and totals', () {
        final samples = objects(s['samples']);
        final steps = objects(s['expected_steps']);
        expect(steps.length, samples.length);
        final t = TickTimer();
        for (var i = 0; i < samples.length; i++) {
          final step = t.advance(
            samples[i]['device_ticks'] as int,
            samples[i]['rx_time_us'] as int,
          );
          final want = steps[i];
          expect(step.kind.name, want['kind'], reason: 'sample $i');
          expect(step.dtTicks, want['dt_ticks'], reason: 'sample $i');
          expect(
            step.dtSeconds,
            closeTo((want['dt_us'] as num) * 1e-6, 1e-12),
            reason: 'sample $i',
          );
        }
        final totals = s['expected_totals'] as Json;
        expect(t.steps, totals['steps']);
        expect(t.discontinuities, totals['discontinuities']);
        expect(t.longGaps, totals['long_gaps']);
        expect(t.missing, totals['missing']);
        expect(t.periodTicks, totals['period_ticks']);
      });

      if (s.containsKey('expected_ticks64')) {
        test('${s['name']}: tickDelta unwraps to 64 bits', () {
          final samples = objects(s['samples']);
          final want = ints(s['expected_ticks64']);
          var previous = samples.first['device_ticks'] as int;
          var total = previous;
          final got = [total];
          for (final sample in samples.skip(1)) {
            final ticks = sample['device_ticks'] as int;
            total += tickDelta(previous, ticks);
            previous = ticks;
            got.add(total);
          }
          expect(got, want);
        });
      }
    }
  });
}
