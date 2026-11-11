import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_ble/wmr_ble.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_companion_app/ui/connect/connect_providers.dart';
import 'package:wmr_companion_app/ui/connect/connect_screen.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';
import 'package:wmr_ws/wmr_ws.dart';

import 'package:wmr_ble/testing.dart';

import 'raw_mode_notifier.dart';

void main() {
  late FakeBleAdapter adapter;

  Future<void> open(WidgetTester tester, {bool rawDefault = true}) async {
    adapter = FakeBleAdapter();
    final transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          appVersionProvider.overrideWith((ref) => '0.3.0+5'),
          lanDiscoveryProvider.overrideWithValue(
            () async => const <WmrWsEndpoint>[],
          ),
          launchAutoConnectEnabledProvider.overrideWithValue(false),
          if (rawDefault) streamModeProvider.overrideWith(RawModeNotifier.new),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
  }

  /// Pumps Connect with the auto-detection selector replaced, so a test can
  /// count detector calls without a vendor plugin.
  Future<void> openWithProbe(
    WidgetTester tester,
    TrackingSourceSelector selector,
  ) async {
    adapter = FakeBleAdapter();
    final transport = UniversalBleTransport(
      adapter: adapter,
      scanTimeout: const Duration(minutes: 5),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realTransportProvider.overrideWithValue(transport),
          appVersionProvider.overrideWith((ref) => '0.3.0+5'),
          lanDiscoveryProvider.overrideWithValue(
            () async => const <WmrWsEndpoint>[],
          ),
          launchAutoConnectEnabledProvider.overrideWithValue(false),
          streamModeProvider.overrideWith(RawModeNotifier.new),
          debugTrackingSelectorProvider.overrideWithValue(selector),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('opens on the real device path with no fake bridge', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Fake bridge'), findsNothing);
    expect(find.text('Real device'), findsNothing);
    expect(find.text('Version 0.3.0+5'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the scan action takes the initial D-pad focus', (tester) async {
    await open(tester);
    await tester.pump();
    final scan = tester.widget<FilledButton>(
      find.byKey(const Key('connect-scan')),
    );
    expect(scan.focusNode?.hasFocus, isTrue);
    await close(tester);
  });

  testWidgets('scan, connect and show MTU and stream counters', (tester) async {
    await open(tester);

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();
    adapter.emitScanResult(
      const BleScanResult(
        deviceId: fakeBridgeDeviceId,
        name: 'WMR Bridge',
        rssi: -48,
      ),
    );
    await tester.pump();
    expect(find.text('WMR Bridge'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    // Stream cancellation needs a real event-loop turn, not just microtasks.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(find.text('State: connected, streaming'), findsOneWidget);
    expect(find.textContaining('MTU (negotiated): 185'), findsOneWidget);
    expect(find.textContaining('LEFT   frames 0'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);

    await close(tester);
  });

  Future<void> connect(WidgetTester tester) async {
    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();
    adapter.emitScanResult(
      const BleScanResult(
        deviceId: fakeBridgeDeviceId,
        name: 'WMR Bridge',
        rssi: -48,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  testWidgets('connects on batched FF14 by default', (tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, rawDefault: false);
    await connect(tester);

    expect(adapter.ccc, ['on ff14']);
    expect(find.text('State: connected, streaming'), findsOneWidget);
    await close(tester);
  });

  testWidgets('FF14 stream panel counts records, not raw frames', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, rawDefault: false);
    await connect(tester);

    final record = Uint8List(wmrDecodedSize)..[0] = wmrDecodedVersion;
    adapter.emitNotification(
      wmrBridgeBatchedCharUuid,
      encodeDecodedBatch([record, record]),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('LEFT'), findsOneWidget);
    expect(find.textContaining('records 2'), findsOneWidget);
    expect(find.textContaining('RIGHT  records 0'), findsOneWidget);
    expect(find.textContaining('batches 1'), findsOneWidget);
    expect(find.textContaining('frames'), findsNothing);
    await close(tester);
  });

  testWidgets('switches the real device between raw and decoded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    await connect(tester);
    expect(find.text('Raw FF11'), findsOneWidget);
    expect(find.text('Open 3D debug view'), findsOneWidget);
    expect(adapter.ccc, ['on ff11']);

    await tester.tap(find.text('Decoded FF12'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(adapter.ccc, ['on ff11', 'off ff11', 'on ff12']);

    await close(tester);
  });

  testWidgets('a refused switch is shown on the connect screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    await connect(tester);
    adapter.disableErrors[wmrBridgeStreamCharUuid] = const BleAdapterException(
      'refused',
    );

    await tester.tap(find.text('Decoded FF12'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Could not turn the previous'), findsOneWidget);
    expect(adapter.ccc, ['on ff11', 'FAIL off ff11']);

    await close(tester);
  });

  testWidgets('Capture switches back to the raw stream first', (tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    await connect(tester);
    await tester.tap(find.text('Decoded FF12'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(adapter.ccc.last, 'on ff12');

    await tester.tap(find.text('Capture'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(adapter.ccc, [
      'on ff11',
      'off ff11',
      'on ff12',
      'off ff12',
      'on ff11',
    ]);
    // The Capture screen schedules a zero-delay refresh when it is built.
    await tester.pump(const Duration(milliseconds: 10));

    await close(tester);
  });

  testWidgets('shows Bluetooth off on scan', (tester) async {
    await open(tester);
    adapter.availabilityState = BleAvailability.poweredOff;

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();

    expect(find.text('State: Bluetooth is off'), findsOneWidget);
    await close(tester);
  });

  testWidgets('shows permission denied on scan', (tester) async {
    await open(tester);
    adapter
      ..permissionsGranted = false
      ..grantOnRequest = false;

    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();

    expect(find.text('State: Bluetooth permission denied'), findsOneWidget);
    await close(tester);
  });

  testWidgets('opens the Neckband controls hint', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const Key('neckband-controls')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('neckband-controls-hint')), findsOneWidget);
    expect(
      find.textContaining('Volume Up and Volume Down move focus'),
      findsOneWidget,
    );
    await close(tester);
  });

  testWidgets('Connect never starts the tracking probe on Android', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final detector = _CountingDetector();
      final selector = TrackingSourceSelector(
        detector: detector,
        flags: const TrackingSourceFlags(viture: true),
        vitureSource: () async => null,
      );

      // SBS on (32:9) and off (phone), so the wrapper rebuilds both ways.
      for (final size in [const Size(3840, 1080), const Size(432, 960)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await openWithProbe(tester, selector);
        await tester.pump();
        await tester.pump();
        expect(
          detector.calls,
          0,
          reason: 'Connect at $size must not start tracking',
        );
        await close(tester);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('opening the Bench starts the tracking probe', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final detector = _CountingDetector();
      final selector = TrackingSourceSelector(
        detector: detector,
        flags: const TrackingSourceFlags(viture: true),
        vitureSource: () async => null,
      );

      await openWithProbe(tester, selector);
      expect(detector.calls, 0);

      await tester.tap(find.byKey(const Key('open-guided-bench')));
      await tester.pump();
      await tester.pump();
      for (var i = 0; i < 10 && detector.calls == 0; i++) {
        await tester.pump();
      }

      expect(detector.calls, greaterThan(0));
      await close(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _CountingDetector implements GlassesDetector {
  int calls = 0;

  @override
  Future<GlassesDetection> detect() async {
    calls++;
    return GlassesDetection.none;
  }
}
