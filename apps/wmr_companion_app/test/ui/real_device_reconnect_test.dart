import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';

import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_ble/testing.dart';

import 'raw_mode_notifier.dart';

/// Drives the app's real-device controller over the fake adapter. These are
/// regression tests for the facade hand-over: after an automatic reconnect
/// both the published counters and the in-session stick centre must come from
/// the new service, not from the one that was disposed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBleAdapter adapter;
  late UniversalBleTransport transport;
  late ProviderContainer container;

  setUp(() {
    adapter = FakeBleAdapter();
    transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    container = ProviderContainer(
      overrides: [
        realTransportProvider.overrideWithValue(transport),
        streamModeProvider.overrideWith(RawModeNotifier.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await transport.dispose();
    });
  });

  void sendFrames(int from, int count) {
    for (var i = 0; i < count; i++) {
      final fragments = encodeFrame(
        syntheticFrame(0, from + i),
        notificationCapacity(185),
      );
      for (final fragment in fragments) {
        adapter.emitNotification(wmrBridgeStreamCharUuid, fragment);
      }
    }
  }

  Future<void> wait([int millis = 300]) =>
      Future<void>.delayed(Duration(milliseconds: millis));

  test('published stats follow the service created by a reconnect', () async {
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    expect(container.read(realDeviceProvider).connected, isTrue);

    sendFrames(0, 2);
    await wait();
    expect(container.read(realDeviceProvider).stats?.hands[0].frames, 2);

    adapter.dropLink();
    await wait(800);
    expect(container.read(realDeviceProvider).connected, isTrue);

    sendFrames(0, 5);
    await wait();
    expect(container.read(realDeviceProvider).stats?.hands[0].frames, 5);
  });

  test('a stick centre set after connect survives a reconnect', () async {
    final controller = container.read(realDeviceProvider.notifier);
    await controller.connect(fakeBridgeDeviceId);
    expect(container.read(realDeviceProvider).connected, isTrue);

    container.read(stickSettingsProvider.notifier).setCentre(0, 0.2, 0.1);
    await wait();

    adapter.dropLink();
    await wait(800);
    expect(container.read(realDeviceProvider).connected, isTrue);

    expect(controller.service!.decodedStats.hands[0].stickCentre, [0.2, 0.1]);
  });
}
