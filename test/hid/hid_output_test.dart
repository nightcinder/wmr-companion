import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion_app/hid/hid_gamepad_transport.dart';
import 'package:wmr_companion_app/hid/hid_output.dart';
import 'package:wmr_companion_app/hid/hid_report.dart';

import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/gamepad/gamepad_providers.dart';

import 'fake_hid.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

DecodedRecord record(int seq, {int buttons = 0, int trigger = 0}) =>
    DecodedRecord(
      hand: 1,
      sequence: seq,
      rxTimeUs: seq * 5000,
      deviceTicks: seq * 50000,
      gyro: const [0, 0, 0],
      accel: const [0, 0, 9.8],
      buttons: buttons,
      trigger: trigger,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport t;
  late ControllerService service;
  late FakeHid hid;
  late ProviderContainer container;

  setUp(() async {
    t = FakeTransport(devices: const [fakeBridgeDevice]);
    service = ControllerService(
      t,
      fakeBridgeDeviceId,
      mode: StreamMode.decoded,
    );
    await service.start();
    hid = FakeHid();
    container = ProviderContainer(
      overrides: [
        hidTransportProvider.overrideWithValue(hid),
        controllerServiceProvider(DebugSource.fake).overrideWithValue(service),
      ],
    );
    container.read(hidOutputProvider); // build, subscribe to status
    addTearDown(() async {
      container.dispose();
      await service.dispose();
      await t.dispose();
    });
  });

  HidOutput out() => container.read(hidOutputProvider.notifier);
  HidOutputState state() => container.read(hidOutputProvider);

  void feed(DecodedRecord r) => t.emit(
    fakeBridgeDeviceId,
    wmrBridgeDecodedCharUuid,
    encodeDecodedRecord(r),
  );

  test('start registers, lists paired hosts and marks running', () async {
    await out().start(DebugSource.fake);
    expect(hid.calls, ['start']);
    expect(state().running, isTrue);
    expect(state().hosts.single.address, 'AA:BB');
    await out().connect('AA:BB');
    await out().requestDiscoverable();
    await out().disconnect();
    expect(hid.calls.skip(1), ['connect AA:BB', 'discoverable', 'disconnect']);
    await out().stop();
    expect(state().running, isFalse);
    expect(hid.calls.last, 'stop');
  });

  test('nothing is sent until a host is connected', () async {
    await out().start(DebugSource.fake);
    feed(record(1, buttons: wmrBtnSqueeze));
    await pump();
    expect(hid.reports, isEmpty);
  });

  test('sends on change only, and the full state on connect', () async {
    await out().start(DebugSource.fake);
    feed(record(1, buttons: wmrBtnSqueeze));
    await pump();
    hid.emit(const HidStatus(HidState.connected, deviceName: 'PC'));
    await pump();
    // The pad as it stood when the host connected.
    expect(hid.reports, hasLength(1));
    expect(hid.reports.single[0] & (1 << 5), isNot(0)); // R1 (squeeze, RIGHT)
    expect(state().status.deviceName, 'PC');

    feed(record(2, buttons: wmrBtnSqueeze)); // same state: no report
    await pump();
    expect(hid.reports, hasLength(1));

    feed(record(3, buttons: wmrBtnSqueeze, trigger: 255));
    await pump();
    expect(hid.reports, hasLength(2));
    expect(hid.reports.last[8], 255); // right trigger
    expect(state().reportsSent, 2);
  });

  test('a new host gets the current state again', () async {
    await out().start(DebugSource.fake);
    hid.emit(const HidStatus(HidState.connected, deviceName: 'PC'));
    await pump();
    final n = hid.reports.length;
    hid.emit(const HidStatus(HidState.registered));
    await pump();
    hid.emit(const HidStatus(HidState.connected, deviceName: 'TV'));
    await pump();
    expect(hid.reports.length, n + 1);
  });

  test('a threshold change is applied without a new sample', () async {
    await out().start(DebugSource.fake);
    feed(record(1, trigger: 100)); // 0.39 of full scale
    await pump();
    hid.emit(const HidStatus(HidState.connected));
    await pump();
    final before = hid.reports.length;
    // R2 lamp (bit 7) is off at the default 0.5 press point.
    expect(hid.reports.last[0] & (1 << 7), 0);
    final c = container.read(gamepadConfigProvider);
    container
        .read(gamepadConfigProvider.notifier)
        .set(c.copyWith(triggerPressThreshold: 0.2));
    await pump();
    expect(hid.reports.length, before + 1);
    expect(hid.reports.last[0] & (1 << 7), isNot(0));
  });

  test('a held trigger in the hysteresis band does not flicker', () async {
    await out().start(DebugSource.fake);
    hid.emit(const HidStatus(HidState.connected));
    await pump();
    // 153/255 = 0.60 crosses the 0.55 press point.
    feed(record(1, trigger: 153));
    await pump();
    expect(hid.reports.last[0] & (1 << 7), isNot(0));
    // 128/255 = 0.50 sits between release 0.45 and press 0.55: stays down.
    feed(record(2, trigger: 128));
    await pump();
    expect(hid.reports.last[0] & (1 << 7), isNot(0));
    // 114/255 = 0.447 reaches the release point: lets go.
    feed(record(3, trigger: 114));
    await pump();
    expect(hid.reports.last[0] & (1 << 7), 0);
  });

  test('send failures are counted and the report is retried', () async {
    await out().start(DebugSource.fake);
    hid.emit(const HidStatus(HidState.connected));
    await pump();
    hid.failSend = true;
    feed(record(1, buttons: wmrBtnMenu));
    await pump();
    expect(state().sendErrors, 1);
    hid.failSend = false;
    feed(record(2, buttons: wmrBtnMenu));
    await pump();
    expect(hid.reports.last[1] & (1 << 3), isNot(0)); // Start (bit 11)
  });

  test('stop ends forwarding', () async {
    await out().start(DebugSource.fake);
    hid.emit(const HidStatus(HidState.connected));
    await pump();
    await out().stop();
    final n = hid.reports.length;
    feed(record(1, buttons: wmrBtnMenu));
    await pump();
    expect(hid.reports.length, n);
  });

  group('MethodChannelHidGamepad', () {
    const channel = MethodChannel('wmr_companion/hid_gamepad');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'bondedHosts') {
              return [
                {'name': 'PC', 'address': 'AA:BB'},
                {'address': 'CC:DD'},
              ];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    });

    test('passes the descriptor and report id, parses hosts', () async {
      final h = MethodChannelHidGamepad();
      await h.start();
      await h.sendReport(Uint8List(hidReportSize));
      final hosts = await h.bondedHosts();
      expect(calls[0].method, 'start');
      expect((calls[0].arguments as Map)['descriptor'], hidReportDescriptor);
      expect((calls[1].arguments as Map)['id'], hidReportId);
      expect(hosts.map((e) => (e.name, e.address)), [
        ('PC', 'AA:BB'),
        ('', 'CC:DD'),
      ]);
    });

    test(
      'without the plugin the calls are no-ops and status says so',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        final h = MethodChannelHidGamepad();
        await h.start();
        await h.sendReport(Uint8List(hidReportSize));
        expect((await h.status.first).state, HidState.unsupported);
      },
    );

    test('status stream starts with a ping', () async {
      final h = MethodChannelHidGamepad(
        events: const EventChannel('wmr_companion/hid_gamepad/events_test'),
      );
      // No handler on the event channel in the test: the first probe call
      // still reaches the method channel.
      unawaited(
        h.status.first
            .timeout(const Duration(milliseconds: 50))
            .then((_) {}, onError: (_) {}),
      );
      await pump();
      expect(calls.map((c) => c.method), contains('ping'));
    });

    test('parses status events', () {
      expect(
        MethodChannelHidGamepad.parseStatus({
          'state': 'connected',
          'device': 'PC',
        }),
        const HidStatus(HidState.connected, deviceName: 'PC'),
      );
      expect(
        MethodChannelHidGamepad.parseStatus({'state': 'nope'}).state,
        HidState.error,
      );
      expect(MethodChannelHidGamepad.parseStatus(3).state, HidState.error);
    });
  });
}
