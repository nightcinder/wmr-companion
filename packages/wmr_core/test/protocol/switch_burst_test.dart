import 'package:test/test.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/switch_burst.dart';

DecodedRecord record({
  int hand = 0,
  int sequence = 1,
  int deviceTicks = 1000,
  int rxTimeUs = 5000,
  double gyroX = 0,
}) => DecodedRecord(
  hand: hand,
  sequence: sequence,
  rxTimeUs: rxTimeUs,
  deviceTicks: deviceTicks,
  gyro: [gyroX, 0, 0],
  accel: [0, 0, 9.8],
);

void main() {
  test('spaces the three samples of a burst 5 ms apart', () {
    final clock = SwitchBurstTimestamps();
    final out = [
      for (var i = 0; i < 3; i++)
        clock.apply(record(sequence: 7, deviceTicks: 1000)),
    ];
    expect(out.map((r) => r.deviceTicks), [1000, 51000, 101000]);
    expect(out.map((r) => r.sequence), [7, 7, 7]);
    expect(out.map((r) => r.rxTimeUs), [5000, 5000, 5000]);
  });

  test('derives a faster Pro Controller spacing from the report period', () {
    final clock = SwitchBurstTimestamps();
    for (var i = 0; i < 3; i++) {
      clock.apply(record(sequence: 1, deviceTicks: 1000));
    }
    // The next report is 8 ms after the previous anchor: 8/3 ms per sample.
    final out = [
      for (var i = 0; i < 3; i++)
        clock.apply(record(sequence: 2, deviceTicks: 81000)),
    ];
    expect(out.map((r) => r.deviceTicks), [81000, 107666, 134332]);
    final next = clock.apply(record(sequence: 3, deviceTicks: 161000));
    expect(next.deviceTicks, 161000);
    expect(
      (next.deviceTicks - out.last.deviceTicks) & 0xffffffff,
      greaterThan(0),
    );
  });

  test('clamps a long report period to the nominal 5 ms', () {
    final clock = SwitchBurstTimestamps();
    for (var i = 0; i < 3; i++) {
      clock.apply(record(sequence: 1, deviceTicks: 0));
    }
    final out = [
      for (var i = 0; i < 3; i++)
        clock.apply(record(sequence: 2, deviceTicks: 500000)),
    ];
    expect(out.map((r) => r.deviceTicks), [500000, 550000, 600000]);
  });

  test('a new sequence starts a new burst at its own anchor', () {
    final clock = SwitchBurstTimestamps();
    clock.apply(record(sequence: 7, deviceTicks: 1000));
    clock.apply(record(sequence: 7, deviceTicks: 1000));
    final next = clock.apply(record(sequence: 8, deviceTicks: 16000));
    expect(next.deviceTicks, 16000);
    expect(clock.sampleIndex, 0);
    expect(clock.isBurstRepeat, isFalse);
  });

  test('already spaced samples keep their values', () {
    final clock = SwitchBurstTimestamps();
    expect(
      clock.apply(record(sequence: 1, deviceTicks: 1000)).deviceTicks,
      1000,
    );
    expect(
      clock.apply(record(sequence: 1, deviceTicks: 51000)).deviceTicks,
      51000,
    );
    expect(
      clock.apply(record(sequence: 1, deviceTicks: 101000)).deviceTicks,
      101000,
    );
  });

  test('a fourth record with the same sequence is a new anchor', () {
    final clock = SwitchBurstTimestamps();
    for (var i = 0; i < 3; i++) {
      clock.apply(record(sequence: 1, deviceTicks: 0));
    }
    final fourth = clock.apply(record(sequence: 1, deviceTicks: 9000));
    expect(fourth.deviceTicks, 9000);
    expect(clock.sampleIndex, 0);
  });

  test('a hand change resets the burst', () {
    final clock = SwitchBurstTimestamps();
    clock.apply(record(hand: 0, sequence: 1, deviceTicks: 1000));
    final other = clock.apply(record(hand: 1, sequence: 1, deviceTicks: 1000));
    expect(other.deviceTicks, 1000);
    expect(clock.sampleIndex, 0);
  });

  test('the tick counter wraps without going backwards', () {
    final clock = SwitchBurstTimestamps();
    const last = 0xffffffff - switchSampleIntervalTicks ~/ 2;
    final a = clock.apply(record(sequence: 1, deviceTicks: last));
    final b = clock.apply(record(sequence: 1, deviceTicks: last));
    expect(a.deviceTicks, last);
    expect((b.deviceTicks - last) & 0xffffffff, switchSampleIntervalTicks);
  });

  test('reset forgets the burst', () {
    final clock = SwitchBurstTimestamps();
    clock.apply(record(sequence: 1, deviceTicks: 1000));
    clock.apply(record(sequence: 1, deviceTicks: 1000));
    clock.reset();
    final after = clock.apply(record(sequence: 1, deviceTicks: 1000));
    expect(after.deviceTicks, 1000);
    expect(clock.sampleIndex, 0);
  });
}
