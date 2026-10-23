import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_hid_android/wmr_companion_hid_android.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
