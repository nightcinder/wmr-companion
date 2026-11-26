import 'dart:async';
import 'dart:convert';
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
  'discoverServices',
  'read',
  'priorityHigh',
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
        expect(adapter.lastMtuTimeout, const Duration(seconds: 5));
        expect(adapter.lastDiscoveryTimeout, const Duration(seconds: 10));
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
      expect(adapter.calls, [
        'connect',
        'requestMtu 517',
        'discoverServices',
        'read',
        'priorityHigh',
        'enableNotifications',
      ]);
    });

    test('MTU TimeoutException from unresponsive peer fails fast, skips priority and discovery, and disconnects', () async {
      const bounded = Duration(milliseconds: 20);
      final timed = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(milliseconds: 30),
        mtuTimeout: bounded,
      );
      addTearDown(timed.dispose);

      adapter.mtuGate = Completer<void>();

      await expectLater(
        timed.connect(id),
        throwsA(
          isA<BleTransportException>().having(
            (e) => e.phase,
            'phase',
            BleLinkPhase.connectFailed,
          ),
        ),
      );

      expect(adapter.lastMtuTimeout, bounded);
      expect(adapter.calls, ['connect', 'requestMtu 517', 'disconnect']);
      expect(adapter.calls, isNot(contains('priorityHigh')));
      expect(adapter.calls, isNot(contains('discoverServices')));
      expect(timed.statusFor(id).phase, BleLinkPhase.connectFailed);
      expect(timed.negotiatedMtu(id), isNull);
      expect(
        await timed.connectionState(id).first,
        BleConnectionState.disconnected,
      );

      // Session state is cleared so a subsequent connect succeeds.
      adapter.calls.clear();
      adapter.mtuGate = null;
      await timed.connect(id);
      expect(timed.statusFor(id).phase, BleLinkPhase.ready);
    });

    test('adapter-thrown MTU TimeoutException fails fast with connectFailed and disconnects', () async {
      adapter.mtuError = TimeoutException('mtu timed out');

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

      expect(adapter.lastMtuTimeout, const Duration(seconds: 5));
      expect(adapter.calls, ['connect', 'requestMtu 517', 'disconnect']);
      expect(adapter.calls, isNot(contains('priorityHigh')));
      expect(adapter.calls, isNot(contains('discoverServices')));
      expect(t.statusFor(id).phase, BleLinkPhase.connectFailed);
    });

    test('discoverServices TimeoutException fails with connectFailed and disconnects', () async {
      const bounded = Duration(milliseconds: 20);
      final timed = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(milliseconds: 30),
        discoveryTimeout: bounded,
      );
      addTearDown(timed.dispose);

      adapter.discoveryGate = Completer<void>();

      await expectLater(
        timed.connect(id),
        throwsA(
          isA<BleTransportException>().having(
            (e) => e.phase,
            'phase',
            BleLinkPhase.connectFailed,
          ),
        ),
      );

      expect(adapter.lastDiscoveryTimeout, bounded);
      expect(adapter.calls, [
        'connect',
        'requestMtu 517',
        'mtuResult 185',
        'discoverServices',
        'disconnect',
      ]);
      expect(timed.statusFor(id).phase, BleLinkPhase.connectFailed);
      expect(timed.negotiatedMtu(id), isNull);
      expect(
        await timed.connectionState(id).first,
        BleConnectionState.disconnected,
      );

      // Session state is cleared so a subsequent connect succeeds.
      adapter.calls.clear();
      adapter.discoveryGate = null;
      await timed.connect(id);
      expect(timed.statusFor(id).phase, BleLinkPhase.ready);
    });

    test('adapter-thrown discoverServices TimeoutException fails with connectFailed and disconnects', () async {
      adapter.discoveryError = TimeoutException('discovery timed out');

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

      expect(adapter.lastDiscoveryTimeout, const Duration(seconds: 10));
      expect(adapter.calls, [
        'connect',
        'requestMtu 517',
        'mtuResult 185',
        'discoverServices',
        'disconnect',
      ]);
      expect(t.statusFor(id).phase, BleLinkPhase.connectFailed);
    });

    test(
      'P1: skips high connection priority on Pi wmr_ble_endpoint bridges',
      () async {
        adapter.readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'wmr_ble_endpoint',
              'protocol': 1,
              'bridge_id': 'pi-bridge',
              'version': '0.2.4',
            }),
          ),
        );

        await connectAndSubscribe();

        expect(adapter.calls, [
          'connect',
          'requestMtu 517',
          'mtuResult 185',
          'discoverServices',
          'read',
          'enableNotifications',
        ]);
        expect(adapter.calls, isNot(contains('priorityHigh')));
        expect(adapter.lastReadTimeout, const Duration(seconds: 5));
        expect(t.status.phase, BleLinkPhase.ready);
        expect(t.status.priorityRequested, isNull);
      },
    );

    test(
      'P2: requests high connection priority on ESP32 plain version FF16',
      () async {
        adapter.readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
          utf8.encode('0.3.19'),
        );

        await connectAndSubscribe();

        expect(adapter.calls, sequence);
        expect(adapter.lastReadTimeout, const Duration(seconds: 5));
        expect(t.status.phase, BleLinkPhase.ready);
        expect(t.status.priorityRequested, isTrue);
      },
    );

    test('P2: requests high connection priority on Pi endpoint when config gate is off', () async {
      final unGated = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(milliseconds: 30),
        skipHighPriorityForPiEndpoints: false,
      );
      addTearDown(unGated.dispose);

      adapter.readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'wmr_ble_endpoint',
            'protocol': 1,
            'bridge_id': 'pi-bridge',
            'version': '0.2.4',
          }),
        ),
      );

      await unGated.connect(id);
      unGated.subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid);
      await pump();

      expect(adapter.calls, contains('priorityHigh'));
      expect(unGated.status.phase, BleLinkPhase.ready);
      expect(unGated.status.priorityRequested, isTrue);
    });

    test(
      'reads FF16 when hasVersion is true even with priority checks disabled',
      () async {
        adapter.supportsPriority = false;
        final unGated = UniversalBleTransport(
          adapter: adapter,
          clock: clock,
          scanTimeout: const Duration(milliseconds: 30),
          skipHighPriorityForPiEndpoints: false,
        );
        addTearDown(unGated.dispose);

        adapter.readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'wmr_ble_endpoint',
              'protocol': 1,
              'bridge_id': 'pi-bridge',
              'version': '0.2.4',
            }),
          ),
        );

        await unGated.connect(id);
        unGated.subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid);
        await pump();

        expect(adapter.calls, [
          'connect',
          'requestMtu 517',
          'mtuResult 185',
          'discoverServices',
          'read',
          'enableNotifications',
        ]);
        expect(unGated.status.phase, BleLinkPhase.ready);
      },
    );

    test(
      'P3: absent FF16 skips read and keeps non-Pi high priority behavior',
      () async {
        adapter.services = const [
          BleServiceInfo(
            uuid: wmrBridgeServiceUuid,
            characteristicUuids: [
              wmrBridgeStreamCharUuid,
              wmrBridgeDecodedCharUuid,
              wmrBridgeBatchedCharUuid,
            ],
          ),
        ];

        await connectAndSubscribe();

        expect(adapter.calls, isNot(contains('read')));
        expect(adapter.calls, [
          'connect',
          'requestMtu 517',
          'mtuResult 185',
          'discoverServices',
          'priorityHigh',
          'enableNotifications',
        ]);
        expect(t.status.phase, BleLinkPhase.ready);
        expect(t.status.priorityRequested, isTrue);
      },
    );

    test(
      'P3: non-timeout FF16 read error records warning and proceeds to ready',
      () async {
        adapter.readError = StateError('gatt read failed');

        await connectAndSubscribe();

        expect(t.status.phase, BleLinkPhase.ready);
        expect(t.status.warnings, contains(contains('Version read failed')));
        expect(adapter.calls, sequence);
        expect(t.status.priorityRequested, isTrue);
      },
    );

    test('P3: FF16 read TimeoutException fails fast with connectFailed and disconnects', () async {
      const bounded = Duration(milliseconds: 20);
      final timed = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        scanTimeout: const Duration(milliseconds: 30),
        versionReadTimeout: bounded,
      );
      addTearDown(timed.dispose);

      adapter.readGate = Completer<void>();

      await expectLater(
        timed.connect(id),
        throwsA(
          isA<BleTransportException>().having(
            (e) => e.phase,
            'phase',
            BleLinkPhase.connectFailed,
          ),
        ),
      );

      expect(adapter.lastReadTimeout, bounded);
      expect(adapter.calls, [
        'connect',
        'requestMtu 517',
        'mtuResult 185',
        'discoverServices',
        'read',
        'disconnect',
      ]);
      expect(adapter.calls, isNot(contains('priorityHigh')));
      expect(timed.statusFor(id).phase, BleLinkPhase.connectFailed);
      expect(
        await timed.connectionState(id).first,
        BleConnectionState.disconnected,
      );

      // Session state is cleared so a subsequent connect succeeds.
      adapter.calls.clear();
      adapter.readGate = null;
      await timed.connect(id);
      expect(timed.statusFor(id).phase, BleLinkPhase.ready);
    });

    test('P3: adapter-thrown FF16 read TimeoutException fails fast with connectFailed and disconnects', () async {
      adapter.readError = TimeoutException('version read timed out');

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

      expect(adapter.lastReadTimeout, const Duration(seconds: 5));
      expect(adapter.calls, [
        'connect',
        'requestMtu 517',
        'mtuResult 185',
        'discoverServices',
        'read',
        'disconnect',
      ]);
      expect(t.statusFor(id).phase, BleLinkPhase.connectFailed);
    });

    test('does not read the status characteristic on its own', () async {
      await connectAndSubscribe();
      expect(
        adapter.readCharacteristics,
        isNot(contains(wmrBridgeStreamCharUuid)),
      );

      final status = await t.readBridgeStatus(id);
      expect(status, isNotNull);
      expect(
        adapter.readCharacteristics.where((c) => c == wmrBridgeStreamCharUuid),
        hasLength(1),
      );
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
        'discoverServices',
        'read',
        'priorityHigh',
        'enableNotifications',
      ]);
      expect(t.status.mtu, 247);

      adapter.emitNotification(wmrBridgeStreamCharUuid, [1, 2, 3]);
      await pump();
      expect(again, isNotNull);
      expect(got, hasLength(1));
    });

    test('a later discovery reuses the connect-time table', () async {
      await connectAndSubscribe();
      final discoveries = adapter.calls
          .where((call) => call == 'discoverServices')
          .length;

      final services = await t.discoverServices(id);

      expect(services.single.uuid, wmrBridgeServiceUuid);
      expect(
        adapter.calls.where((call) => call == 'discoverServices').length,
        discoveries,
      );
    });

    test(
      'a link drop during MTU negotiation aborts setup before ready',
      () async {
        adapter.mtuGate = Completer<void>();
        final connecting = expectLater(
          t.connect(id),
          throwsA(
            isA<BleTransportException>().having(
              (e) => e.phase,
              'phase',
              BleLinkPhase.connectionLost,
            ),
          ),
        );
        await pump();

        adapter.dropLink();
        await pump();
        adapter.mtuGate!.complete();
        await connecting;

        expect(t.status.phase, BleLinkPhase.connectionLost);
        expect(adapter.calls, isNot(contains('discoverServices')));
        expect(
          await t.connectionState(id).first,
          BleConnectionState.disconnected,
        );
      },
    );

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

  group('busy CCCD writes', () {
    UniversalBleTransport fastRetry() {
      final transport = UniversalBleTransport(
        adapter: adapter,
        clock: clock,
        enableRetryDelay: const Duration(milliseconds: 5),
      );
      addTearDown(transport.dispose);
      return transport;
    }

    Future<void> settleUntil(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('condition not met');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('retries after the stack settles', () async {
      final t2 = fastRetry();
      await t2.connect(id);
      adapter.enableBusyCount = 1;

      final stream = t2.subscribe(
        id,
        wmrBridgeServiceUuid,
        wmrBridgeStreamCharUuid,
      );
      await settleUntil(() => adapter.ccc.contains('on ff11'));

      expect(
        adapter.calls.where((c) => c == 'enableNotifications'),
        hasLength(2),
      );
      expect(adapter.ccc, ['BUSY on ff11', 'on ff11']);
      expect(t2.status.phase, BleLinkPhase.ready);
      expect(stream, isNotNull);
    });

    test('drops the link when the write never settles', () async {
      final t2 = fastRetry();
      await t2.connect(id);
      adapter.enableBusyCount = 5;

      final errors = <Object>[];
      t2
          .subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid)
          .listen((_) {}, onError: errors.add);
      await settleUntil(() => adapter.calls.contains('disconnect'));

      expect(errors.single, isA<BleStreamException>());
      expect(
        adapter.calls.where((c) => c == 'enableNotifications'),
        hasLength(3),
      );
      expect(
        await t2.connectionState(id).first,
        BleConnectionState.disconnected,
      );
      expect(t2.status.phase, BleLinkPhase.disconnected);
    });

    test('shares one CCCD write between duplicate subscribers', () async {
      await t.connect(id);
      t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid);
      await pump();
      final again = t.subscribe(
        id,
        wmrBridgeServiceUuid,
        wmrBridgeStreamCharUuid,
      );
      await pump();

      expect(
        adapter.calls.where((c) => c == 'enableNotifications'),
        hasLength(1),
      );
      expect(adapter.ccc, ['on ff11']);

      final got = <BleNotification>[];
      again.listen(got.add);
      adapter.emitNotification(wmrBridgeStreamCharUuid, [7]);
      await pump();
      expect(got.single.value, [7]);
    });

    test('queues a write behind an in-flight CCCD write', () async {
      await t.connect(id);
      adapter.enableGate = Completer<void>();
      t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeStreamCharUuid);
      await pump();

      var wrote = false;
      final write = t
          .write(
            id,
            wmrBridgeServiceUuid,
            wmrBridgeStreamCharUuid,
            Uint8List.fromList([1]),
          )
          .then((_) => wrote = true);
      await pump();
      expect(wrote, isFalse);

      adapter.enableGate!.complete();
      await write;
      expect(wrote, isTrue);
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
      final start = adapter.calls.singleWhere((c) => c.startsWith('startScan'));
      expect(start, contains(wmrBridgeServiceUuid));
      expect(start, contains(wmrBridgeDeviceName));
      expect(t.status.phase, BleLinkPhase.scanning);
      await sub.cancel();
    });

    test(
      'lists a bridge the system already connected and does not time out',
      () async {
        adapter.systemDeviceResults = const [
          BleScanResult(deviceId: 'aa', name: 'WMR Bridge', rssi: null),
        ];
        final results = <BleScanResult>[];
        final errors = <Object>[];
        final done = Completer<void>();
        t.scan().listen(
          results.add,
          onError: errors.add,
          onDone: done.complete,
        );
        await done.future;

        expect(results.single.deviceId, 'aa');
        expect(
          adapter.calls.where((c) => c.startsWith('systemDevices')),
          hasLength(1),
        );
        expect(errors, isEmpty);
      },
    );

    test('a system-device failure leaves the ordinary scan running', () async {
      adapter.systemDevicesError = StateError('unsupported');
      final sub = t.scan().listen((_) {}, onError: (_) {});
      await pump();
      await pump();

      expect(t.status.phase, BleLinkPhase.scanning);
      expect(
        adapter.calls.where((c) => c.startsWith('startScan')),
        hasLength(1),
      );
      await sub.cancel();
    });

    test('does not list an unrelated system device', () async {
      adapter.systemDeviceResults = const [
        BleScanResult(
          deviceId: 'bb',
          name: 'Headphones',
          rssi: null,
          serviceUuids: ['0000180f-0000-1000-8000-00805f9b34fb'],
        ),
      ];
      final results = <BleScanResult>[];
      final sub = t.scan().listen(results.add, onError: (_) {});
      await pump();
      await pump();

      expect(results, isEmpty);
      await sub.cancel();
    });

    test('retains an FF10-filtered system device with empty serviceUuids and a BlueZ alias', () async {
      adapter.systemDeviceResults = const [
        BleScanResult(deviceId: 'pi-1', name: 'wmrpi', rssi: null),
      ];
      final results = <BleScanResult>[];
      final done = Completer<void>();
      t.scan().listen(results.add, onError: (_) {}, onDone: done.complete);
      await done.future;

      expect(results, hasLength(1));
      expect(results.single.deviceId, 'pi-1');
      expect(results.single.name, 'wmrpi');
    });

    test(
      'system enumeration does not time out the scan while it runs',
      () async {
        final pending = Completer<List<BleScanResult>>();
        adapter.systemDevicesPending.add(pending);
        final results = <BleScanResult>[];
        final errors = <Object>[];
        final done = Completer<void>();
        t.scan().listen(
          results.add,
          onError: errors.add,
          onDone: done.complete,
        );
        await pump();
        await pump();

        // The enumeration takes longer than scanTimeout (30 ms): the deadline
        // must start only after it settles, or the scan would close first.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(done.isCompleted, isFalse);
        expect(errors, isEmpty);

        pending.complete(const [
          BleScanResult(deviceId: 'aa', name: 'WMR Bridge', rssi: null),
        ]);
        await done.future;

        expect(results.single.deviceId, 'aa');
        expect(errors, isEmpty);
      },
    );

    test(
      'a late result from a cancelled scan does not suppress the new timeout',
      () async {
        final stale = Completer<List<BleScanResult>>();
        adapter.systemDevicesPending.add(stale);
        final first = t.scan().listen((_) {}, onError: (_) {});
        await pump();
        await pump();
        await first.cancel();

        final errors = <Object>[];
        final done = Completer<void>();
        t.scan().listen((_) {}, onError: errors.add, onDone: done.complete);
        await pump();
        stale.complete(const [
          BleScanResult(deviceId: 'aa', name: 'WMR Bridge', rssi: null),
        ]);
        await done.future;

        expect(
          (errors.single as BleTransportException).phase,
          BleLinkPhase.scanTimeout,
        );
      },
    );

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

    test('coalesces concurrent preflight requestPermissions calls', () async {
      final gate = Completer<void>();
      final coalescingAdapter = _GatedPermissionAdapter(gate);
      final transport = UniversalBleTransport(
        adapter: coalescingAdapter,
        clock: clock,
        scanTimeout: const Duration(minutes: 1),
      );
      addTearDown(transport.dispose);

      final scanSub = transport.scan().listen((_) {}, onError: (_) {});
      final connectFuture = transport.connect('bridge-1');
      await pump();

      expect(
        coalescingAdapter.calls.where((c) => c == 'requestPermissions'),
        hasLength(1),
      );

      gate.complete();
      await connectFuture;
      await scanSub.cancel();
    });

    test(
      'cancelling an older scan stream is a no-op after a newer scan starts',
      () async {
        final slow = UniversalBleTransport(
          adapter: adapter,
          clock: clock,
          scanTimeout: const Duration(minutes: 1),
        );
        addTearDown(slow.dispose);

        final oldResults = <BleScanResult>[];
        final newResults = <BleScanResult>[];
        final oldSub = slow.scan().listen(oldResults.add, onError: (_) {});
        await pump();
        final newSub = slow.scan().listen(newResults.add, onError: (_) {});
        await pump();

        await oldSub.cancel();
        await pump();

        adapter.emitScanResult(
          const BleScanResult(
            deviceId: 'bridge-2',
            name: 'WMR Bridge',
            rssi: -45,
          ),
        );
        await pump();

        expect(oldResults, isEmpty);
        expect(newResults, hasLength(1));
        expect(newResults.single.deviceId, 'bridge-2');
        expect(adapter.calls.where((c) => c == 'stopScan'), isEmpty);
        await newSub.cancel();
      },
    );
  });

  group('UniversalBleAdapter', () {
    test('dispatches connection parameters to multiple adapters', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final first = UniversalBleAdapter();
      final second = UniversalBleAdapter();
      final firstEvents = <AdapterConnectionParams>[];
      final secondEvents = <AdapterConnectionParams>[];
      final sub1 = first.connectionParams.listen(firstEvents.add);
      final sub2 = second.connectionParams.listen(secondEvents.add);
      addTearDown(() async {
        await sub1.cancel();
        await sub2.cancel();
      });

      UniversalBleAdapter.dispatchConnectionParametersForTest('bridge-1', 12);
      await pump();

      expect(firstEvents, hasLength(1));
      expect(firstEvents.single.deviceId, 'bridge-1');
      expect(firstEvents.single.intervalUs, 12 * 1250);
      expect(secondEvents, hasLength(1));
      expect(secondEvents.single.deviceId, 'bridge-1');
      expect(secondEvents.single.intervalUs, 12 * 1250);
    });
  });

  group('cold-path deduplication', () {
    test('first FF16 read reuses _setup read and second FF16 read hits adapter fresh', () async {
      const doc1 =
          '{"type":"wmr_ble_endpoint","bridge_id":"b1","hosts":["10.0.0.1"],"port":8765}';
      const doc2 =
          '{"type":"wmr_ble_endpoint","bridge_id":"b1","hosts":["10.0.0.2"],"port":8765}';
      adapter.readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
        doc1.codeUnits,
      );

      await t.connect(id);
      expect(adapter.calls.where((c) => c == 'read'), hasLength(1));

      // First read consumes the one-shot _setup value without a second GATT read.
      final first = await t.read(
        id,
        wmrBridgeServiceUuid,
        wmrBridgeVersionCharUuid,
      );
      expect(String.fromCharCodes(first), doc1);
      expect(adapter.calls.where((c) => c == 'read'), hasLength(1));

      // Post-T1 update on the bridge: second read must hit the adapter fresh.
      adapter.readValues[wmrBridgeVersionCharUuid] = Uint8List.fromList(
        doc2.codeUnits,
      );
      final second = await t.read(
        id,
        wmrBridgeServiceUuid,
        wmrBridgeVersionCharUuid,
      );
      expect(String.fromCharCodes(second), doc2);
      expect(adapter.calls.where((c) => c == 'read'), hasLength(2));
    });

    test('stopScan when idle skips adapter stopScan call', () async {
      await t.stopScan();
      expect(adapter.calls.where((c) => c == 'stopScan'), isEmpty);
    });
  });
}

class _GatedPermissionAdapter extends FakeBleAdapter {
  _GatedPermissionAdapter(this.gate) {
    permissionsGranted = false;
  }

  final Completer<void> gate;
  int _inFlight = 0;

  @override
  Future<void> requestPermissions() async {
    calls.add('requestPermissions');
    _inFlight++;
    if (_inFlight > 1) {
      throw StateError('OPERATION_IN_PROGRESS');
    }
    try {
      await gate.future;
      permissionsGranted = true;
    } finally {
      _inFlight--;
    }
  }
}
