import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/ble/ble_adapter.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion_app/ble/universal_ble_transport.dart';
import 'package:wmr_core/protocol/gatt.dart';

import 'fake_adapter.dart';

const id = fakeBridgeDeviceId;
const ff11 = wmrBridgeStreamCharUuid;
const ff12 = wmrBridgeDecodedCharUuid;
const ff14 = wmrBridgeBatchedCharUuid;

Future<void> pump() => Future<void>.delayed(Duration.zero);

class StepClock extends MonotonicClock {
  int now = 0;

  @override
  int get nowUs => now;
}

void main() {
  late FakeAdapter adapter;
  late StepClock clock;
  late UniversalBleTransport t;

  setUp(() {
    adapter = FakeAdapter();
    clock = StepClock();
    t = UniversalBleTransport(adapter: adapter, clock: clock);
  });
  tearDown(() => t.dispose());

  Stream<BleNotification> sub(String char) =>
      t.subscribe(id, wmrBridgeServiceUuid, char);

  /// Collects errors from [s] and swallows the data.
  List<BleStreamException> faults(Stream<BleNotification> s) {
    final out = <BleStreamException>[];
    s.listen((_) {}, onError: (Object e) => out.add(e as BleStreamException));
    return out;
  }

  test('FF12 alone enables only FF12', () async {
    await t.connect(id);
    sub(ff12);
    await pump();
    expect(adapter.ccc, ['on ff12']);
  });

  test(
    'switching raw to decoded writes 0x0000 to FF11 before enabling FF12',
    () async {
      await t.connect(id);
      sub(ff11);
      await pump();
      final f = faults(sub(ff12));
      await pump();

      expect(adapter.ccc, ['on ff11', 'off ff11', 'on ff12']);
      expect(f, isEmpty);
      expect(t.status.phase, BleLinkPhase.ready);
    },
  );

  test('and back again', () async {
    await t.connect(id);
    sub(ff11);
    await pump();
    sub(ff12);
    await pump();
    sub(ff11);
    await pump();
    expect(adapter.ccc, [
      'on ff11',
      'off ff11',
      'on ff12',
      'off ff12',
      'on ff11',
    ]);
  });

  test('switching while connecting enables only the last choice', () async {
    final connecting = t.connect(id);
    sub(ff11);
    sub(ff12);
    await connecting;
    await pump();
    expect(adapter.ccc, ['on ff12']);
  });

  test('re-selecting the active stream does not touch the CCC', () async {
    await t.connect(id);
    sub(ff12);
    sub(ff12);
    await pump();
    expect(adapter.ccc, ['on ff12']);
  });

  group('ATT error 0x80', () {
    test(
      'is a stream fault, not a failed connection, and not silent',
      () async {
        await t.connect(id);
        // The bridge already has FF11 on from something the transport does not
        // know about (stale state): the enable of FF12 is refused.
        await adapter.enableNotifications(id, wmrBridgeServiceUuid, ff11);
        final f = faults(sub(ff12));
        await pump();

        expect(f, hasLength(1));
        expect(f.single.kind, BleStreamFaultKind.otherStreamActive);
        expect(f.single.attError, 0x80);
        expect(f.single.characteristicUuid, ff12);
        expect(t.status.phase, BleLinkPhase.ready);
        expect(adapter.ccc, ['on ff11', 'FAIL on ff12']);
      },
    );

    test('is recognised from a platform message', () {
      expect(parseAttError('Operation failed with ATT error: 0x80'), 0x80);
      expect(parseAttError('GATT error, status 128'), 128);
      expect(parseAttError('status=128'), 128);
      expect(parseAttError('failed 0x80 now'), 0x80);
      expect(parseAttError('timeout'), isNull);
    });

    test(
      'a different enable error is its own kind and fails the link',
      () async {
        adapter.enableErrors[ff12] = const BleAdapterException('no such char');
        await t.connect(id);
        final f = faults(sub(ff12));
        await pump();

        expect(f.single.kind, BleStreamFaultKind.enableFailed);
        expect(f.single.attError, isNull);
        expect(t.status.phase, BleLinkPhase.connectFailed);
      },
    );

    test('a failed disable stops the switch and says so', () async {
      await t.connect(id);
      sub(ff11);
      await pump();
      adapter.disableErrors[ff11] = const BleAdapterException('busy');
      final f = faults(sub(ff12));
      await pump();

      expect(f.single.kind, BleStreamFaultKind.disableFailed);
      expect(f.single.characteristicUuid, ff11);
      expect(adapter.ccc, ['on ff11', 'FAIL off ff11']);

      // Retrying once the disable works recovers without a 0x80.
      adapter.disableErrors.clear();
      final f2 = faults(sub(ff12));
      await pump();
      expect(f2, isEmpty);
      expect(adapter.ccc.skip(2), ['off ff11', 'on ff12']);
    });
  });

  group('reconnect', () {
    test('re-enables the wanted stream from scratch', () async {
      await t.connect(id);
      sub(ff12);
      await pump();
      adapter.dropLink();
      await pump();
      adapter.ccc.clear();

      await t.connect(id);
      await pump();
      expect(adapter.ccc, ['on ff12']);
    });

    test('after a switch only the new stream comes back', () async {
      await t.connect(id);
      sub(ff11);
      sub(ff12);
      await pump();
      adapter.dropLink();
      await pump();
      adapter.ccc.clear();

      await t.connect(id);
      await pump();
      expect(adapter.ccc, ['on ff12']);
    });

    test(
      'a new subscribe after reconnect to the other stream switches cleanly',
      () async {
        await t.connect(id);
        sub(ff12);
        await pump();
        adapter.dropLink();
        await pump();
        adapter.ccc.clear();

        await t.connect(id);
        final f = faults(sub(ff11));
        await pump();
        // Setup re-enables what was wanted before the drop, then the switch
        // writes 0x0000 first; never a refused enable.
        expect(adapter.ccc, ['on ff12', 'off ff12', 'on ff11']);
        expect(f, isEmpty);
      },
    );
  });

  test('unsubscribe writes 0x0000 and forgets the stream', () async {
    await t.connect(id);
    sub(ff12);
    await pump();
    await t.unsubscribe(id, wmrBridgeServiceUuid, ff12);
    expect(adapter.ccc, ['on ff12', 'off ff12']);

    adapter.dropLink();
    await pump();
    adapter.ccc.clear();
    await t.connect(id);
    expect(adapter.ccc, isEmpty);
  });

  test('FF12 notifications are stamped at the transport boundary', () async {
    await t.connect(id);
    final got = <BleNotification>[];
    sub(ff12).listen(got.add);
    await pump();

    clock.now = 1234;
    adapter.emitNotification(ff12, List.filled(56, 1));
    clock.now = 9999;
    await pump();

    expect(got.single.receivedAtUs, 1234);
    expect(got.single.value, hasLength(56));
  });

  group('FF14 joins the exclusion', () {
    String short(String uuid) => uuid.substring(4, 8);

    for (final (from, to) in [
      (ff11, ff12),
      (ff11, ff14),
      (ff12, ff11),
      (ff12, ff14),
      (ff14, ff11),
      (ff14, ff12),
    ]) {
      test('${short(from)} to ${short(to)} writes 0x0000 first', () async {
        await t.connect(id);
        sub(from);
        await pump();
        final f = faults(sub(to));
        await pump();
        expect(adapter.ccc, [
          'on ${short(from)}',
          'off ${short(from)}',
          'on ${short(to)}',
        ]);
        expect(f, isEmpty);
      });
    }

    test(
      'a stale FF12 on the bridge makes the FF14 enable fail with 0x80',
      () async {
        await t.connect(id);
        await adapter.enableNotifications(id, wmrBridgeServiceUuid, ff12);
        final f = faults(sub(ff14));
        await pump();
        expect(f.single.kind, BleStreamFaultKind.otherStreamActive);
        expect(f.single.characteristicUuid, ff14);
        expect(t.status.phase, BleLinkPhase.ready);
      },
    );

    test('switching while connecting enables only FF14', () async {
      final connecting = t.connect(id);
      sub(ff12);
      sub(ff11);
      sub(ff14);
      await connecting;
      await pump();
      expect(adapter.ccc, ['on ff14']);
    });
  });
}
