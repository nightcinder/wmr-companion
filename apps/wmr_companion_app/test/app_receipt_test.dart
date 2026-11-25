import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/testing.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_companion_app/app.dart';
import 'package:wmr_companion_app/services/bench_receipt_log.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_core/ble/fake_transport.dart';

class _FakeCompositeTransport extends FakeTransport
    implements CompositeBleTransport {
  _FakeCompositeTransport(String deviceId)
    : super(devices: [FakeDevice(id: deviceId, mtu: 4096)]);

  @override
  final WmrWsTransport tcp = WmrWsTransport(endpoints: const []);

  final StreamController<String> _receipts = StreamController.broadcast();
  final Map<String, Map<String, Object?>?> timelines = {};

  @override
  Stream<String> get tcpReceipts => _receipts.stream;

  @override
  Stream<String> get fallbackReadinessChanges => const Stream.empty();

  @override
  BleFallbackReadiness fallbackReadinessFor(String deviceId) =>
      const BleFallbackReadiness(verifiedCount: 0, unverifiedCount: 0);

  void emitReceipt(String deviceId, Map<String, Object?> timeline) {
    timelines[deviceId] = timeline;
    if (!_receipts.isClosed) _receipts.add(deviceId);
  }

  @override
  Map<String, Object?>? linkTimelineFor(String deviceId) => timelines[deviceId];

  @override
  Future<void> dispose() async {
    await _receipts.close();
    await tcp.dispose();
    await super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(BenchReceiptLog.channelName);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  });

  testWidgets(
    'Transition 10: WmrCompanionApp emits WmrBenchReceipt immediately on '
    'tcpReceipts and rebinds when connectWifi swaps _wifiTransport',
    (tester) async {
      final created = <_FakeCompositeTransport>[];
      final ble = UniversalBleTransport(
        adapter: FakeBleAdapter(),
        scanTimeout: const Duration(minutes: 5),
      );

      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(ble),
          launchAutoConnectEnabledProvider.overrideWithValue(false),
          compositeWifiTransportFactoryProvider.overrideWithValue((endpoint) {
            final t = _FakeCompositeTransport(endpoint.resolvedDeviceId);
            created.add(t);
            return WifiLink(t);
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: WmrCompanionApp(receiptLog: BenchReceiptLog(enabled: true)),
        ),
      );
      await tester.pump();

      final notifier = container.read(realDeviceProvider.notifier);
      await tester.runAsync(
        () => notifier.connectWifi(host: '192.168.1.10', port: 8765),
      );
      await tester.pump();

      expect(created, hasLength(1));
      const deviceId = '192.168.1.10:8765';
      const timeline1 = <String, Object?>{
        'first_tcp_record_us': 1100,
        'first_tcp_record_session': '192.168.1.10:8765',
        'first_tcp_record_wall_us': 1700000000001100,
        'episodes': <Object?>[],
      };

      // Emit receipt and flush microtasks only (no 1 s timer advance).
      await tester.runAsync(() async {
        created[0].emitReceipt(deviceId, timeline1);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'log');
      expect(calls.single.arguments, {
        'tag': 'WmrBenchReceipt',
        'message':
            'session=192.168.1.10:8765 first_tcp_record_us=1100 '
            'first_tcp_record_wall_us=1700000000001100',
      });

      // Duplicate in episodes[] does not re-emit.
      await tester.runAsync(() async {
        created[0].emitReceipt(deviceId, {
          'episodes': [timeline1],
          'first_tcp_record_us': null,
          'first_tcp_record_session': null,
        });
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(calls, hasLength(1));

      // Same-host reconnect swaps _wifiTransport: WmrCompanionApp rebinds to
      // the new transport and emits immediately when it stamps a receipt.
      await tester.runAsync(
        () => notifier.connectWifi(host: '192.168.1.10', port: 8765),
      );
      await tester.pump();
      expect(created, hasLength(2));

      await tester.runAsync(() async {
        created[1].emitReceipt(deviceId, const <String, Object?>{
          'first_tcp_record_us': 2200,
          'first_tcp_record_session': '192.168.1.10:8765',
          'first_tcp_record_wall_us': 1700000000002200,
          'episodes': <Object?>[],
        });
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(calls, hasLength(2));
      expect(calls.last.arguments, {
        'tag': 'WmrBenchReceipt',
        'message':
            'session=192.168.1.10:8765 first_tcp_record_us=2200 '
            'first_tcp_record_wall_us=1700000000002200',
      });
    },
  );

  testWidgets(
    'WmrCompanionApp emits nothing when BenchReceiptLog is disabled',
    (tester) async {
      final created = <_FakeCompositeTransport>[];
      final ble = UniversalBleTransport(
        adapter: FakeBleAdapter(),
        scanTimeout: const Duration(minutes: 5),
      );

      final container = ProviderContainer(
        overrides: [
          realTransportProvider.overrideWithValue(ble),
          launchAutoConnectEnabledProvider.overrideWithValue(false),
          compositeWifiTransportFactoryProvider.overrideWithValue((endpoint) {
            final t = _FakeCompositeTransport(endpoint.resolvedDeviceId);
            created.add(t);
            return WifiLink(t);
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: WmrCompanionApp(receiptLog: BenchReceiptLog(enabled: false)),
        ),
      );
      await tester.pump();

      await tester.runAsync(
        () => container
            .read(realDeviceProvider.notifier)
            .connectWifi(host: '192.168.1.10', port: 8765),
      );
      await tester.pump();

      await tester.runAsync(() async {
        created.single.emitReceipt('192.168.1.10:8765', const <String, Object?>{
          'first_tcp_record_us': 3300,
          'first_tcp_record_session': '192.168.1.10:8765',
          'first_tcp_record_wall_us': 1700000000003300,
          'episodes': <Object?>[],
        });
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(calls, isEmpty);
    },
  );
}
