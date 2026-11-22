import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';

const id = fakeBridgeDeviceId;

const settleBound = Duration(seconds: 1);

Future<void> pump() => Future<void>.delayed(Duration.zero);

Future<Object?> throwsBluetoothOff(Future<void> future) => expectLater(
  future,
  throwsA(
    isA<BleTransportException>().having(
      (e) => e.phase,
      'phase',
      BleLinkPhase.bluetoothOff,
    ),
  ),
);

/// One adapter power cycle, transition by transition. The radio is the only
/// part of the link the OS reports reliably: a GATT client left holding a
/// dead stack is what wedged the app on hardware, so every transition here
/// also asserts what the transport stopped calling.
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

  group('adapter power transitions', () {
    test('off loses the link without touching the adapter', () async {
      await connectSubscribed();
      final callsAtReady = adapter.calls.length;
      final cccAtReady = adapter.ccc.length;

      adapter.emitAvailability(BleAvailability.poweredOff);
      await pump();

      expect(t.statusFor(id).phase, BleLinkPhase.bluetoothOff);
      expect(t.statusFor(id).message, 'Bluetooth is turned off');
      expect(
        await t.connectionState(id).first,
        BleConnectionState.disconnected,
      );
      expect(t.negotiatedMtu(id), isNull);
      // The teardown is local: a GATT call into the dead stack is what
      // wedged the client on hardware.
      expect(adapter.calls, hasLength(callsAtReady));
      expect(adapter.ccc, hasLength(cccAtReady));
    });

    Future<void> expectOffAndRedial(
      Future<Object?> failed,
      List<String> callsBeforeOff,
    ) async {
      await failed.timeout(settleBound);
      expect(t.statusFor(id).phase, BleLinkPhase.bluetoothOff);
      expect(
        await t.connectionState(id).first,
        BleConnectionState.disconnected,
      );
      expect(t.negotiatedMtu(id), isNull);
      expect(
        () => t.subscribe(id, wmrBridgeServiceUuid, wmrBridgeBatchedCharUuid),
        throwsStateError,
      );
      expect(
        adapter.calls.skip(callsBeforeOff.length),
        isNot(contains('disconnect')),
      );

      final callsBeforeRedial = adapter.calls.length;
      adapter.emitAvailability(BleAvailability.poweredOn);
      await t.connect(id).timeout(settleBound);
      expect(
        adapter.calls.skip(callsBeforeRedial),
        containsAllInOrder(['connect', 'requestMtu 517', 'discoverServices']),
      );
      expect(t.statusFor(id).phase, BleLinkPhase.ready);
    }

    test('off releases a connect that never resolves', () async {
      adapter.connectGate = Completer<void>();
      final failed = throwsBluetoothOff(t.connect(id));
      await pump();
      expect(adapter.calls, ['connect']);

      final beforeOff = adapter.calls.toList();
      adapter.emitAvailability(BleAvailability.poweredOff);
      adapter.connectGate = null;
      await expectOffAndRedial(failed, beforeOff);
    });

    test(
      'a connect that throws during radio loss reports Bluetooth off',
      () async {
        final gate = adapter.connectGate = Completer<void>();
        final failed = throwsBluetoothOff(t.connect(id));
        await pump();
        expect(adapter.calls, ['connect']);

        final beforeOff = adapter.calls.toList();
        adapter.emitAvailability(BleAvailability.poweredOff);
        gate.completeError(StateError('stack closed during connect'));
        adapter.connectGate = null;
        await expectOffAndRedial(failed, beforeOff);
      },
    );

    test('off releases an MTU request that never resolves', () async {
      adapter.mtuGate = Completer<void>();
      final failed = throwsBluetoothOff(t.connect(id));
      await pump();
      expect(adapter.calls, ['connect', 'requestMtu 517']);

      final beforeOff = adapter.calls.toList();
      adapter.emitAvailability(BleAvailability.poweredOff);
      adapter.mtuGate = null;
      await expectOffAndRedial(failed, beforeOff);
    });

    test('off releases a discovery request that never resolves', () async {
      adapter.discoveryGate = Completer<void>();
      final failed = throwsBluetoothOff(t.connect(id));
      await pump();
      expect(adapter.calls, [
        'connect',
        'requestMtu 517',
        'mtuResult 185',
        'priorityHigh',
        'discoverServices',
      ]);

      final beforeOff = adapter.calls.toList();
      adapter.emitAvailability(BleAvailability.poweredOff);
      adapter.discoveryGate = null;
      await expectOffAndRedial(failed, beforeOff);
    });

    test('off before discovery prevents calling the dead stack', () async {
      final beforeOff = Completer<List<String>>();
      final sub = t.statusChanges.listen((status) {
        if (status.phase != BleLinkPhase.negotiatingMtu ||
            beforeOff.isCompleted) {
          return;
        }
        beforeOff.complete(adapter.calls.toList());
        adapter.emitAvailability(BleAvailability.poweredOff);
      });
      addTearDown(sub.cancel);
      final failed = throwsBluetoothOff(t.connect(id));
      final calls = await beforeOff.future.timeout(settleBound);
      expect(calls, ['connect', 'requestMtu 517']);
      await failed.timeout(settleBound);
      expect(adapter.calls, isNot(contains('discoverServices')));
      await expectOffAndRedial(failed, calls);
    });

    test(
      'off releases discovery even after a platform link-loss event',
      () async {
        final services = adapter.services;
        adapter.services = [];
        final gate = adapter.discoveryGate = Completer<void>();
        final failed = throwsBluetoothOff(t.connect(id));
        await pump();
        expect(adapter.calls.last, 'discoverServices');

        adapter.dropLink();
        await pump();
        expect(t.statusFor(id).phase, BleLinkPhase.connectionLost);
        final beforeOff = adapter.calls.toList();
        adapter.emitAvailability(BleAvailability.poweredOff);
        adapter.discoveryGate = null;
        adapter.services = services;
        await expectOffAndRedial(failed, beforeOff);

        final ready = t.statusFor(id);
        gate.complete(); // The old empty service table cannot replace the new one.
        await pump();
        expect(t.statusFor(id), same(ready));
        expect(await t.discoverServices(id), services);
        expect(adapter.calls, isNot(contains('disconnect')));
      },
    );

    test('on followed by a redial re-subscribes the wanted stream', () async {
      await connectSubscribed();

      adapter.emitAvailability(BleAvailability.poweredOff);
      await pump();
      adapter.emitAvailability(BleAvailability.poweredOn);
      await t.connect(id);
      await pump();

      expect(t.statusFor(id).phase, BleLinkPhase.ready);
      expect(await t.connectionState(id).first, BleConnectionState.connected);
      expect(adapter.ccc.where((c) => c == 'on ff14'), hasLength(2));
      expect(adapter.calls.where((c) => c == 'connect'), hasLength(2));
    });

    test('a dial while the radio stays off never reaches the stack', () async {
      await connectSubscribed();
      adapter.emitAvailability(BleAvailability.poweredOff);
      await pump();
      final callsWhenOff = adapter.calls.length;

      // The host (or its automatic recovery) tries while the radio is still
      // off: the preflight classifies it and no GATT call is made.
      await throwsBluetoothOff(t.connect(id));
      expect(adapter.calls, hasLength(callsWhenOff));

      adapter.emitAvailability(BleAvailability.poweredOn);
      await t.connect(id);
      await pump();
      expect(t.statusFor(id).phase, BleLinkPhase.ready);
    });

    test(
      'a scan ends with the radio instead of calling the dead stack',
      () async {
        final errors = <Object>[];
        final sub = t.scan().listen((_) {}, onError: errors.add);
        await pump();
        expect(t.status.phase, BleLinkPhase.scanning);

        adapter.emitAvailability(BleAvailability.poweredOff);
        await pump();

        expect(
          (errors.single as BleTransportException).phase,
          BleLinkPhase.bluetoothOff,
        );
        // The platform already stopped the scan when the radio died; a host
        // stop must not call into the dead stack either.
        await t.stopScan();
        expect(adapter.calls, isNot(contains('stopScan')));
        await sub.cancel();
      },
    );

    test('a rapid cycle preserves the new dial after a late error', () async {
      final gate = adapter.connectGate = Completer<void>();
      final failed = throwsBluetoothOff(t.connect(id));
      await pump();
      expect(adapter.calls, ['connect']);

      adapter.emitAvailability(BleAvailability.poweredOff);
      adapter.emitAvailability(BleAvailability.poweredOn);
      adapter.connectGate = null;
      final second = t.connect(id);
      await failed.timeout(settleBound);
      await second.timeout(settleBound);
      expect(adapter.calls.where((c) => c == 'connect'), hasLength(2));
      expect(adapter.calls.where((c) => c == 'discoverServices'), hasLength(1));
      final ready = t.statusFor(id);
      expect(ready.phase, BleLinkPhase.ready);

      gate.completeError(StateError('abandoned connect later failed'));
      await pump();
      expect(t.statusFor(id), same(ready));
      expect(await t.connectionState(id).first, BleConnectionState.connected);
      expect(adapter.calls, isNot(contains('disconnect')));
    });
  });
}
