import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';

import 'package:wmr_ble/testing.dart';

class StepClock extends MonotonicClock {
  int now = 0;

  @override
  int get nowUs => now;
}

const id = fakeBridgeDeviceId;
const sequence = [
  'connect',
  'requestMtu 517',
  'mtuResult 185',
  'priorityHigh',
  'discoverServices',
  'enableNotifications',
];

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeBleAdapter adapter;
  late StepClock clock;
  late UniversalBleTransport t;

  setUp(() {
    adapter = FakeBleAdapter();
    clock = StepClock();
    t = UniversalBleTransport(
      adapter: adapter,
      clock: clock,
      scanTimeout: const Duration(milliseconds: 30),
    );
  });
  tearDown(() => t.dispose());

  Future<Stream<BleNotification>> connectAndSubscribe() async {
    await t.connect(id);
    final s = t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid);
    await pump();
    return s;
  }

  group('connection sequence', () {
    test(
      'runs in order and records the negotiated MTU, not the request',
      () async {
        await connectAndSubscribe();

        expect(adapter.calls, sequence);
        expect(t.status.phase, BleLinkPhase.ready);
        expect(t.status.mtu, 185);
        expect(t.negotiatedMtu(id), 185);
        expect(t.status.priorityRequested, isTrue);
        expect(await t.connectionState(id).first, BleConnectionState.connected);
      },
    );

    test('skips connection priority where the platform has none', () async {
      adapter.supportsPriority = false;
      await connectAndSubscribe();

      expect(adapter.calls, isNot(contains('priorityHigh')));
      expect(t.status.priorityRequested, isNull);
    });

    test('subscribe waits for the MTU result', () async {
      adapter.mtuGate = Completer<void>();
      final connected = t.connect(id);
      t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid);
      await pump();

      expect(adapter.calls, ['connect', 'requestMtu 517']);

      adapter.mtuGate!.complete();
      await connected;
      await pump();

      expect(adapter.calls, sequence);
      expect(
        adapter.calls.where((c) => c == 'enableNotifications'),
        hasLength(1),
      );
    });

    test('an MTU failure is a warning and the MTU stays unknown', () async {
      adapter.mtuError = StateError('no mtu');
      await connectAndSubscribe();

      expect(t.status.mtu, isNull);
      expect(t.status.warnings.single, contains('MTU request failed'));
      expect(t.status.phase, BleLinkPhase.ready);
    });

    test('does not read the status characteristic on its own', () async {
      await connectAndSubscribe();
      expect(adapter.calls, isNot(contains('read')));

      final status = await t.readBridgeStatus(id);
      expect(status, isNotNull);
      expect(adapter.calls.where((c) => c == 'read'), hasLength(1));
    });

    test('reports the interval only once the platform provides it', () async {
      await connectAndSubscribe();
      var info = await t.connectionInfo(id);
      expect(info.connectionIntervalUs, isNull);
      expect(info.phy, isNull);
      expect(info.mtu, 185);

      adapter.emitParams(id, 7500);
      await pump();
      info = await t.connectionInfo(id);
      expect(info.connectionIntervalUs, 7500);
    });
  });

  group('reconnect', () {
    test('repeats the whole sequence and re-enables notifications', () async {
      final stream = await connectAndSubscribe();
      final got = <BleNotification>[];
      stream.listen(got.add);

      adapter.dropLink();
      await pump();
      expect(t.status.phase, BleLinkPhase.connectionLost);
      expect(
        await t.connectionState(id).first,
        BleConnectionState.disconnected,
      );

      adapter.calls.clear();
      adapter.negotiatedMtu = 247;
      await t.connect(id);
      final again = t.subscribe(
        id,
        wmrBridgeServiceUuid,
        wmrBridgeStreamCharUuid,
      );
      await pump();

      expect(adapter.calls, [
        'connect',
        'requestMtu 517',
        'mtuResult 247',
        'priorityHigh',
        'discoverServices',
        'enableNotifications',
      ]);
      expect(t.status.mtu, 247);

      adapter.emitNotification(wmrBridgeStreamCharUuid, [1, 2, 3]);
      await pump();
      expect(again, isNotNull);
      expect(got, hasLength(1));
    });

    test('a user disconnect is not reported as a lost connection', () async {
      await connectAndSubscribe();
      await t.disconnect(id);

      expect(t.status.phase, BleLinkPhase.disconnected);
      expect(adapter.calls.last, 'disconnect');
    });
  });

  group('notifications', () {
    test('are stamped when received, before anything consumes them', () async {
      final stream = await connectAndSubscribe();
      final got = <BleNotification>[];
      stream.listen(got.add);

      clock.now = 1000;
      adapter.emitNotification(wmrBridgeStreamCharUuid, [1]);
      clock.now = 2500;
      adapter.emitNotification(wmrBridgeStreamCharUuid, [2]);
      clock.now = 9000; // later than both; must not leak into the stamps
      await pump();

      expect(got.map((n) => n.receivedAtUs), [1000, 2500]);
      expect(got.map((n) => n.value.single), [1, 2]);
    });

    test('golden frames reassemble through transport and service', () async {
      final lines = File('test/fixtures/controller_frames.txt')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty && !l.startsWith('#'));
      final golden = [
        for (final (i, line) in lines.indexed)
          WmrFrame(
            hand: i & 1,
            sequence: 1 + (i >> 1),
            data: Uint8List.fromList([
              for (final b in line.trim().split(RegExp(r'\s+')).skip(1))
                int.parse(b, radix: 16),
            ]),
          ),
      ];
      expect(golden.length, greaterThanOrEqualTo(4));

      for (final mtu in [23, 185]) {
        adapter.negotiatedMtu = mtu;
        final transport = UniversalBleTransport(adapter: adapter, clock: clock);
        final service = ControllerService(transport, id);
        final frames = <ReceivedFrame>[];
        await service.start();
        service.frames.listen(frames.add);
        await pump();

        final capacity = notificationCapacity(transport.negotiatedMtu(id)!);
        clock.now = 777;
        for (final f in golden) {
          for (final fragment in encodeFrame(f, capacity)) {
            adapter.emitNotification(wmrBridgeStreamCharUuid, fragment);
          }
        }
        await pump();

        expect(frames.map((f) => f.frame), golden, reason: 'MTU $mtu');
        expect(frames.every((f) => f.receivedAtUs == 777), isTrue);
        final stats = service.stats;
        expect(
          stats.hands.map((h) => h.frames).reduce((a, b) => a + b),
          golden.length,
        );
        expect(
          stats.hands.every((h) => h.gaps == 0 && h.incomplete == 0),
          isTrue,
        );
        expect(stats.errors, 0);

        await service.dispose();
        await transport.dispose();
      }
    });
  });

  group('failures', () {
    test('permission denied stops before any GATT call', () async {
      adapter
        ..permissionsGranted = false
        ..grantOnRequest = false;

      await expectLater(
        t.connect(id),
        throwsA(
          isA<BleTransportException>().having(
            (e) => e.phase,
            'phase',
            BleLinkPhase.permissionDenied,
          ),
        ),
      );
      expect(t.status.phase, BleLinkPhase.permissionDenied);
      expect(t.status.isFailure, isTrue);
      expect(adapter.calls, ['requestPermissions']);
    });

    test('permission is requested when missing and then granted', () async {
      adapter.permissionsGranted = false;
      await t.connect(id);
      expect(adapter.calls.first, 'requestPermissions');
      expect(t.status.phase, BleLinkPhase.ready);
    });

    test('Bluetooth off is reported and nothing is attempted', () async {
      adapter.availabilityState = BleAvailability.poweredOff;

      await expectLater(
        t.connect(id),
        throwsA(
          isA<BleTransportException>().having(
            (e) => e.phase,
            'phase',
            BleLinkPhase.bluetoothOff,
          ),
        ),
      );
      expect(t.status.phase, BleLinkPhase.bluetoothOff);
      expect(adapter.calls, isNot(contains('connect')));
      expect(
        await t.connectionState(id).first,
        BleConnectionState.disconnected,
      );
    });

    test('unauthorized radio counts as permission denied', () async {
      adapter.availabilityState = BleAvailability.unauthorized;
      await expectLater(t.connect(id), throwsA(isA<BleTransportException>()));
      expect(t.status.phase, BleLinkPhase.permissionDenied);
    });

    test('connect failure is reported and cleaned up', () async {
      adapter.connectError = StateError('timeout');

      await expectLater(t.connect(id), throwsA(isA<BleTransportException>()));
      expect(t.status.phase, BleLinkPhase.connectFailed);
      expect(adapter.calls, ['connect', 'disconnect']);
    });

    test('missing FF10/FF11 is reported', () async {
      adapter.services = const [];

      await expectLater(t.connect(id), throwsA(isA<BleTransportException>()));
      expect(t.status.phase, BleLinkPhase.serviceNotFound);
    });

    test('subscribe without a connection throws', () {
      expect(
        () => t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid),
        throwsStateError,
      );
    });
  });

  group('scan', () {
    test('filters on service and name and passes results through', () async {
      final results = <BleScanResult>[];
      final sub = t.scan().listen(results.add, onError: (_) {});
      await pump();
      adapter.emitScanResult(
        const BleScanResult(deviceId: 'aa', name: 'WMR Bridge', rssi: -60),
      );
      await pump();

      expect(results.single.deviceId, 'aa');
      expect(adapter.calls.single, contains(wmrBridgeServiceUuid));
      expect(adapter.calls.single, contains(wmrBridgeDeviceName));
      expect(t.status.phase, BleLinkPhase.scanning);
      await sub.cancel();
    });

    test('times out when nothing is found', () async {
      final errors = <Object>[];
      final done = Completer<void>();
      t.scan().listen((_) {}, onError: errors.add, onDone: done.complete);
      await done.future;

      expect(
        (errors.single as BleTransportException).phase,
        BleLinkPhase.scanTimeout,
      );
      expect(t.status.phase, BleLinkPhase.scanTimeout);
      expect(adapter.calls, contains('stopScan'));
    });

    test(
      'permission denied and Bluetooth off surface on the scan stream',
      () async {
        adapter
          ..permissionsGranted = false
          ..grantOnRequest = false;
        await expectLater(
          t.scan(),
          emitsError(
            isA<BleTransportException>().having(
              (e) => e.phase,
              'phase',
              BleLinkPhase.permissionDenied,
            ),
          ),
        );

        adapter
          ..permissionsGranted = true
          ..availabilityState = BleAvailability.poweredOff;
        await expectLater(
          t.scan(),
          emitsError(
            isA<BleTransportException>().having(
              (e) => e.phase,
              'phase',
              BleLinkPhase.bluetoothOff,
            ),
          ),
        );
      },
    );

    test(
      'suspends scanning while inactive and resumes with the same filters',
      () async {
        final slow = UniversalBleTransport(
          adapter: adapter,
          clock: clock,
          scanTimeout: const Duration(minutes: 1),
        );
        addTearDown(slow.dispose);

        final sub = slow.scan().listen((_) {});
        await pump();
        expect(slow.status.phase, BleLinkPhase.scanning);
        final firstStart = adapter.calls.lastWhere(
          (c) => c.startsWith('startScan'),
        );

        await slow.handleAppLifecycle(BleAppLifecycle.inactive);
        expect(adapter.calls, contains('stopScan'));
        expect(slow.status.phase, BleLinkPhase.idle);

        await slow.handleAppLifecycle(BleAppLifecycle.resumed);
        final starts = adapter.calls
            .where((c) => c.startsWith('startScan'))
            .toList();
        expect(starts, hasLength(2));
        expect(starts.last, firstStart);
        expect(slow.status.phase, BleLinkPhase.scanning);

        await sub.cancel();
      },
    );

    test('a pause during preflight prevents the scan from starting', () async {
      final slow = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(minutes: 1),
      );
      addTearDown(slow.dispose);
      adapter.availabilityGate = Completer<void>();

      final sub = slow.scan().listen((_) {});
      await pump();
      final pause = slow.handleAppLifecycle(BleAppLifecycle.paused);
      adapter.availabilityGate!.complete();
      await pause;
      await pump();

      expect(adapter.calls.where((c) => c.startsWith('startScan')), isEmpty);

      await slow.handleAppLifecycle(BleAppLifecycle.resumed);
      expect(
        adapter.calls.where((c) => c.startsWith('startScan')),
        hasLength(1),
      );
      await sub.cancel();
    });

    test('a quick pause/resume pair ends scanning, not stopped', () async {
      final slow = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(minutes: 1),
      );
      addTearDown(slow.dispose);

      final sub = slow.scan().listen((_) {});
      await pump();

      await Future.wait([
        slow.handleAppLifecycle(BleAppLifecycle.paused),
        slow.handleAppLifecycle(BleAppLifecycle.resumed),
      ]);

      expect(slow.status.phase, BleLinkPhase.scanning);
      expect(
        adapter.calls.where((c) => c.startsWith('startScan')),
        hasLength(2),
      );
      await sub.cancel();
    });

    test('scan() while paused and a resume start the adapter once', () async {
      final slow = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(minutes: 1),
      );
      addTearDown(slow.dispose);

      await slow.handleAppLifecycle(BleAppLifecycle.paused);
      final sub = slow.scan().listen((_) {});
      await slow.handleAppLifecycle(BleAppLifecycle.resumed);
      await pump();

      expect(
        adapter.calls.where((c) => c.startsWith('startScan')),
        hasLength(1),
      );
      expect(slow.status.phase, BleLinkPhase.scanning);
      await sub.cancel();
    });

    test('a failed resume reports the real preflight cause', () async {
      final slow = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(minutes: 1),
      );
      addTearDown(slow.dispose);
      final errors = <Object>[];
      final sub = slow.scan().listen((_) {}, onError: errors.add);
      await pump();

      await slow.handleAppLifecycle(BleAppLifecycle.paused);
      adapter.availabilityState = BleAvailability.poweredOff;
      await slow.handleAppLifecycle(BleAppLifecycle.resumed);
      await pump();

      expect(
        (errors.single as BleTransportException).phase,
        BleLinkPhase.bluetoothOff,
      );
      await sub.cancel();
    });
  });
}
