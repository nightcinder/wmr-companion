import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';

const id = fakeBridgeDeviceId;

Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Keeps two marks a real event-loop turn apart, so an ordering assert
/// between them reads a true gap rather than a same-tick coincidence.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// The keys `UniversalBleTransport.subscribeTimelineFor` reports: one
/// `<mark>_us` per GATT step of the dial, plus the adapter's radio pair.
const _markKeys = [
  'gatt_connect_start_us',
  'service_discovery_done_us',
  'ff14_cccd_write_us',
  'first_ff14_notification_us',
  'disconnect_us',
  'radio_off_us',
  'radio_on_us',
];

int _mark(Map<String, Object?> marks, String key) => marks[key]! as int;

/// The GATT timeline marks a dial records, in the order the plan's
/// subscribe proof needs them: connect start, service discovery, FF14 CCCD
/// write, first FF14 notification. Two marks the dial records without
/// yielding in between can share a microsecond, so only the pairs a
/// [settle] separates are asserted strictly.
void main() {
  late FakeBleAdapter adapter;
  late UniversalBleTransport t;

  setUp(() {
    adapter = FakeBleAdapter();
    t = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 1),
    );
  });
  tearDown(() => t.dispose());

  Future<void> connectSubscribed() async {
    await t.connect(id);
    t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid);
    await pump();
    expect(adapter.ccc, contains('on ff14'));
  }

  group('subscribe timeline', () {
    test('a dial records each GATT step in order', () async {
      await t.connect(id);
      await settle();
      t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid);
      await pump();
      await settle();
      adapter.emitNotification(wmrBridgeBatchedCharUuid, [1]);
      await pump();

      final marks = t.subscribeTimelineFor(id)!;
      expect(marks.keys, unorderedEquals(_markKeys));
      final connectStart = _mark(marks, 'gatt_connect_start_us');
      final discovery = _mark(marks, 'service_discovery_done_us');
      final cccd = _mark(marks, 'ff14_cccd_write_us');
      final firstNotification = _mark(marks, 'first_ff14_notification_us');
      // Mark order: the CCCD write follows discovery and the first record
      // follows the write, each across a real gap. Discovery only follows
      // the connect start: both land inside one dial's awaited sequence.
      expect(discovery, greaterThanOrEqualTo(connectStart));
      expect(cccd, greaterThan(discovery));
      expect(firstNotification, greaterThan(cccd));
      // Nothing died and the radio never moved: those marks have not
      // landed on a first dial.
      expect(marks['disconnect_us'], isNull);
      expect(marks['radio_off_us'], isNull);
      expect(marks['radio_on_us'], isNull);
    });

    test('a radio off/on cycle re-marks the redial after the radio', () async {
      await connectSubscribed();
      adapter.emitNotification(wmrBridgeBatchedCharUuid, [1]);
      await pump();
      final before = t.subscribeTimelineFor(id)!;
      expect(before['first_ff14_notification_us'], isA<int>());

      adapter.emitAvailability(BleAvailability.poweredOff);
      await pump();
      adapter.emitAvailability(BleAvailability.poweredOn);
      await settle();

      // The host redials once the radio is back; the transport never
      // redials on its own.
      await t.connect(id);
      await pump();
      expect(adapter.ccc.where((c) => c == 'on ff14'), hasLength(2));
      await settle();
      adapter.emitNotification(wmrBridgeBatchedCharUuid, [2]);
      await pump();

      final marks = t.subscribeTimelineFor(id)!;
      final off = _mark(marks, 'radio_off_us');
      final on = _mark(marks, 'radio_on_us');
      final disconnect = _mark(marks, 'disconnect_us');
      final connectStart = _mark(marks, 'gatt_connect_start_us');
      final discovery = _mark(marks, 'service_discovery_done_us');
      final cccd = _mark(marks, 'ff14_cccd_write_us');
      final firstNotification = _mark(marks, 'first_ff14_notification_us');
      // The radio pair brackets the loss the cycle caused; the disconnect
      // the radio handler records can share its microsecond with the off.
      expect(on, greaterThan(off));
      expect(disconnect, greaterThanOrEqualTo(off));
      // The redial re-marked every step, after the radio returned and
      // after the marks the first dial left.
      expect(connectStart, greaterThan(on));
      expect(
        connectStart,
        greaterThan(before['first_ff14_notification_us']! as int),
      );
      expect(discovery, greaterThanOrEqualTo(connectStart));
      expect(cccd, greaterThan(before['ff14_cccd_write_us']! as int));
      expect(firstNotification, greaterThan(cccd));
    });

    test(
      'a bridge drop is redialled once and re-marked from the disconnect',
      () async {
        await connectSubscribed();
        adapter.emitNotification(wmrBridgeBatchedCharUuid, [1]);
        await pump();
        final before = t.subscribeTimelineFor(id)!;

        // The bridge's radio died and recovered (T8's recovery succeeded),
        // but the phone's link only reports lost. The transport never
        // redials on its own, so the app decides when to dial again.
        adapter.dropLink();
        await pump();
        final marksAtDrop = t.subscribeTimelineFor(id)!;
        final disconnect = _mark(marksAtDrop, 'disconnect_us');
        expect(t.statusFor(id).phase, BleLinkPhase.connectionLost);
        expect(
          disconnect,
          greaterThan(before['first_ff14_notification_us']! as int),
        );

        // The app redials once: the recovery's marks follow the disconnect,
        // and no spin follows — a second dial would have to be the host's.
        await settle();
        await t.connect(id);
        await pump();
        expect(adapter.ccc.where((c) => c == 'on ff14'), hasLength(2));
        await settle();
        adapter.emitNotification(wmrBridgeBatchedCharUuid, [2]);
        await pump();
        await pump();
        expect(adapter.calls.where((c) => c == 'connect'), hasLength(2));

        final marks = t.subscribeTimelineFor(id)!;
        final connectStart = _mark(marks, 'gatt_connect_start_us');
        final discovery = _mark(marks, 'service_discovery_done_us');
        final cccd = _mark(marks, 'ff14_cccd_write_us');
        final firstNotification = _mark(marks, 'first_ff14_notification_us');
        expect(connectStart, greaterThan(disconnect));
        expect(discovery, greaterThanOrEqualTo(connectStart));
        expect(cccd, greaterThan(before['ff14_cccd_write_us']! as int));
        expect(firstNotification, greaterThan(cccd));
      },
    );

    test(
      'a dial that fails before the link keeps the marks it reached',
      () async {
        adapter.connectError = StateError('no route to host');
        await expectLater(
          t.connect(id),
          throwsA(
            isA<BleTransportException>().having(
              (e) => e.phase,
              'phase',
              BleLinkPhase.connectFailed,
            ),
          ),
        );
        final failed = t.subscribeTimelineFor(id)!;
        // The dial began and ended; nothing between the two landed.
        expect(failed['gatt_connect_start_us'], isA<int>());
        expect(failed['service_discovery_done_us'], isNull);
        expect(failed['ff14_cccd_write_us'], isNull);
        expect(failed['first_ff14_notification_us'], isNull);
        expect(failed['disconnect_us'], isA<int>());

        // The next dial re-marks from its own start, after the failed one.
        adapter.connectError = null;
        await settle();
        await t.connect(id);
        t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid);
        await pump();
        final marks = t.subscribeTimelineFor(id)!;
        expect(
          _mark(marks, 'gatt_connect_start_us'),
          greaterThan(_mark(failed, 'disconnect_us')),
        );
        expect(_mark(marks, 'service_discovery_done_us'), isA<int>());
        expect(_mark(marks, 'ff14_cccd_write_us'), isA<int>());
        // No record arrived yet, and the failed dial left none behind.
        expect(marks['first_ff14_notification_us'], isNull);
      },
    );
  });
}
