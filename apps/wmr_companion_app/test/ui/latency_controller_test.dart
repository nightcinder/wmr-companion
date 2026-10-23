import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/ble/fake_wmr_bridge.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_core/services/latency_files.dart';
import 'package:wmr_core/services/latency_recorder.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/latency/latency_providers.dart';

class _Clock implements MonotonicClock {
  int now = 5000000;

  @override
  int get nowUs => now;
}

void main() {
  late Directory dir;
  late _Clock clock;
  late ProviderContainer container;
  final shared = <SavedLatencyRun>[];

  LatencyController controller() =>
      container.read(latencyControllerProvider.notifier);
  LatencyState state() => container.read(latencyControllerProvider);

  Future<void> until(bool Function() test) async {
    // A run finishes through a real periodic tick and a file save, so give it
    // room on a loaded CI machine rather than assuming a sub-second turnaround.
    for (var i = 0; i < 2500 && !test(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(test(), isTrue);
  }

  void setUpContainer(Future<LatencyInput?> Function(DebugSource) input) {
    container = ProviderContainer(
      overrides: [
        latencyInputProvider.overrideWithValue(input),
        latencyStoreProvider.overrideWith(
          (ref) => LatencyStore(Directory('${dir.path}/latency')),
        ),
        latencyTickProvider.overrideWithValue(const Duration(milliseconds: 1)),
        echoIntervalProvider.overrideWithValue(const Duration(milliseconds: 5)),
        echoTimeoutProvider.overrideWithValue(const Duration(milliseconds: 50)),
        shareLatencyProvider.overrideWithValue((r) async => shared.add(r)),
      ],
    );
    container.listen(latencyControllerProvider, (_, _) {});
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('latency_ui');
    clock = _Clock();
    shared.clear();
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  test('a run on the fake bridge FF12 stream measures and saves', () async {
    final transport = FakeTransport(
      devices: const [fakeBridgeDevice],
      clock: clock,
    );
    final service = ControllerService(
      transport,
      fakeBridgeDeviceId,
      mode: StreamMode.decoded,
    );
    await service.start();
    addTearDown(() async {
      await service.dispose();
      await transport.dispose();
    });
    // LEFT report 30 is lost (the fake bridge still consumes its sequence
    // number), so both the sequence and the ticks show one missing.
    final bridge = FakeWmrBridge(
      transport,
      dropRecord: (hand, seq) => hand == wmrHandLeft && seq == 30,
    );
    setUpContainer((_) async => LatencyInput.fromService(service));

    controller().selectDuration(null);
    await controller().start(DebugSource.fake);
    expect(state().stage, LatencyStage.running);

    for (var i = 0; i < 100; i++) {
      clock.now += 10000;
      bridge.tick();
    }
    await Future<void>.delayed(Duration.zero);
    await controller().stop();

    expect(state().stage, LatencyStage.finished);
    final report = state().report!;
    expect(report.stream, 'decoded');
    expect(report.links[fakeBridgeDeviceId]!.mtu, isNotNull);
    expect(report.durationUs, 1000000);
    final left = report.hands[wmrHandLeft];
    final right = report.hands[wmrHandRight];
    expect(left.records, 99);
    expect(left.sequenceGaps, 1);
    expect(left.missingFromTicks, 1);
    expect(left.periodUs, 10000);
    expect(right.records, 100);
    expect(right.missingFromTicks, 0);
    expect(right.interArrival.p50, 10000);
    expect(right.delay!.max, 0);

    final saved = state().saved!;
    final csv = File(saved.csvPath).readAsLinesSync();
    expect(csv.first, startsWith('hand,bridge_id,sequence,arrival_us'));
    expect(csv, hasLength(1 + 199));
    expect(File(saved.jsonPath).readAsStringSync(), contains('"LEFT"'));
    expect(state().runs.map((r) => r.csvPath), [saved.csvPath]);

    await controller().share(saved);
    expect(shared, [saved]);

    controller().reset();
    expect(state().stage, LatencyStage.idle);
    expect(state().runs, hasLength(1));
  });

  test('a timed run stops by itself; raw frames are counted', () async {
    final frames = StreamController<ReceivedFrame>.broadcast();
    addTearDown(frames.close);
    var incomplete = 0;
    setUpContainer(
      (_) async => LatencyInput(
        frames: frames.stream,
        samples: const Stream<DecodedSample>.empty(),
        modeChanges: const Stream<ModeState>.empty(),
        clock: clock,
        mode: StreamMode.raw,
        bridgeIds: const ['test-bridge'],
        linkInfo: (_) async => const BleConnectionInfo(mtu: 23, rssi: -70),
        counters: () => {'incomplete_frames': incomplete},
      ),
    );

    controller().selectDuration(30);
    await controller().start(DebugSource.real);
    for (var seq = 1; seq <= 10; seq++) {
      clock.now += 5000;
      frames.add(
        ReceivedFrame(syntheticFrame(wmrHandRight, seq * 2), clock.now),
      );
    }
    incomplete = 3;
    await Future<void>.delayed(Duration.zero);
    expect(state().stage, LatencyStage.running);

    clock.now += 30000000;
    await until(() => state().stage == LatencyStage.finished);
    final report = state().report!;
    expect(report.stream, 'raw');
    expect(report.links['test-bridge']!.mtu, 23);
    expect(report.links['test-bridge']!.rssiEnd, -70);
    expect(report.counters, {'incomplete_frames': 3});
    final right = report.hands[wmrHandRight];
    expect(right.records, 10);
    expect(right.sequenceGaps, 9);
    expect(right.missingFromTicks, isNull);
    expect(state().saved, isNotNull);
  });

  test('no connection: an error, no run', () async {
    setUpContainer((_) async => null);
    await controller().start(DebugSource.real);
    expect(state().stage, LatencyStage.idle);
    expect(state().error, 'Not connected to the bridge.');
  });

  group('stream choice', () {
    late FakeTransport transport;
    late ControllerService service;
    late FakeWmrBridge bridge;

    Future<void> setUpStream({StreamMode mode = StreamMode.decoded}) async {
      transport = FakeTransport(
        devices: const [fakeBridgeDevice],
        clock: clock,
      );
      service = ControllerService(transport, fakeBridgeDeviceId, mode: mode);
      await service.start();
      bridge = FakeWmrBridge(transport);
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });
      setUpContainer((_) async => LatencyInput.fromService(service));
    }

    test('each selector value applies its mode through the service', () async {
      await setUpStream();
      const choices = [
        (LatencyStream.raw, StreamMode.raw),
        (LatencyStream.decoded, StreamMode.decoded),
        (LatencyStream.batched, StreamMode.batched),
        (LatencyStream.none, StreamMode.none),
      ];
      for (final (choice, mode) in choices) {
        await controller().selectStream(DebugSource.fake, choice);
        expect(state().streamChoice, choice);
        expect(service.mode, mode);
      }
      // Turning off goes through ControllerService -> transport.unsubscribe.
      expect(transport.cccLog.last, 'off $wmrBridgeBatchedCharUuid');
    });

    test('no-stream run reports round trip, no stream figures, and restores '
        'after Stop', () async {
      await setUpStream();
      await controller().selectStream(DebugSource.fake, LatencyStream.none);
      expect(service.mode, StreamMode.none);

      controller().selectDuration(null);
      await controller().start(DebugSource.fake);
      expect(state().stage, LatencyStage.running);
      await until(() => (state().report?.echo?.answered ?? 0) >= 2);
      for (var i = 0; i < 20; i++) {
        clock.now += 10000;
        bridge.tick();
      }
      await Future<void>.delayed(Duration.zero);
      await controller().stop();

      final report = state().report!;
      expect(report.stream, 'none');
      expect(report.echo, isNotNull);
      expect(report.echo!.answered, greaterThanOrEqualTo(2));
      expect(report.echo!.timeouts, 0);
      for (final hand in report.hands) {
        expect(hand.records, 0);
        expect(hand.arrivals, 0);
        expect(hand.missingFromTicks, isNull);
      }
      expect(state().error, isNull);

      // The mode the screen turned off comes back at the end.
      expect(service.mode, StreamMode.decoded);
      expect(state().streamChoice, LatencyStream.decoded);

      final saved = state().saved!;
      expect(File(saved.csvPath).readAsLinesSync(), [LatencyRow.csvHeader]);
      final json = File(saved.jsonPath).readAsStringSync();
      expect(json, contains('"stream": "none"'));
      expect(json, contains('"ping_interval_us": 5000'));
      expect(saved.echoCsvPath, isNotNull);
    });

    test('a timed no-stream run restores the mode when it ends', () async {
      await setUpStream(mode: StreamMode.raw);
      await controller().selectStream(DebugSource.fake, LatencyStream.none);
      controller().selectDuration(1);
      await controller().start(DebugSource.fake);
      expect(service.mode, StreamMode.none);

      clock.now += 2000000;
      await until(() => state().stage == LatencyStage.finished);

      expect(state().report!.stream, 'none');
      expect(service.mode, StreamMode.raw);
      expect(state().streamChoice, LatencyStream.raw);
    });

    test(
      'disposing while stop is in flight does not touch a disposed ref',
      () async {
        await setUpStream(mode: StreamMode.raw);
        await controller().selectStream(DebugSource.fake, LatencyStream.none);
        controller().selectDuration(null);
        await controller().start(DebugSource.fake);
        expect(state().stage, LatencyStage.running);

        // The user leaves the screen while the run is being saved: the provider
        // is disposed between stop()'s awaits. It must finish without reading
        // state or the ref again.
        final stopping = controller().stop();
        container.dispose();
        await expectLater(stopping, completes);

        // tearDown disposes the container again; give it a fresh one.
        container = ProviderContainer();
      },
    );

    test('leaving during a no-stream run restores the mode', () async {
      await setUpStream();
      await controller().selectStream(DebugSource.fake, LatencyStream.none);
      await controller().start(DebugSource.fake);
      await until(() => (state().report?.echo?.answered ?? 0) >= 1);
      expect(service.mode, StreamMode.none);

      container.dispose();
      // The restore is fired without waiting; give it a turn.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(service.mode, StreamMode.decoded);
      // The tear-down disposes the container again; that is harmless.
      container = ProviderContainer();
    });
  });

  group('round trip', () {
    late FakeTransport transport;
    late ControllerService service;
    late FakeWmrBridge bridge;

    Future<void> setUpBridge({
      FakeDevice device = fakeBridgeDevice,
      bool echoEnabled = true,
    }) async {
      transport = FakeTransport(devices: [device], clock: clock);
      service = ControllerService(
        transport,
        device.id,
        mode: StreamMode.decoded,
      );
      await service.start();
      bridge = FakeWmrBridge(transport, echoEnabled: echoEnabled);
      // Every ping takes 4 ms of phone time between write and answer.
      final inner = transport.onWrite!;
      transport.onWrite = (w) {
        clock.now += 4000;
        return inner(w);
      };
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });
      setUpContainer((_) async => LatencyInput.fromService(service));
      controller().selectDuration(null);
    }

    test('pings during a run; the report and an echo CSV have them', () async {
      await setUpBridge();
      await controller().start(DebugSource.fake);
      expect(state().echoNote, isNull);
      await until(() => (state().report?.echo?.answered ?? 0) >= 3);
      bridge.tick();
      await controller().stop();

      final echo = state().report!.echo!;
      expect(echo.answered, greaterThanOrEqualTo(3));
      expect(echo.timeouts, 0);
      expect(
        echo.rtt.p50,
        3700,
      ); // 4000 us write to answer, minus 300 turnaround
      expect(echo.endToEnd.p50, 4000);
      expect(echo.turnaround.p50, 300);
      expect(transport.cccLog, contains('on $wmrBridgeEchoCharUuid'));
      expect(transport.cccLog.last, 'off $wmrBridgeEchoCharUuid');

      final saved = state().saved!;
      expect(saved.echoCsvPath, isNotNull);
      final lines = File(saved.echoCsvPath!).readAsLinesSync();
      expect(lines.first, startsWith('ping_id,t1_us'));
      expect(lines.length - 1, echo.answered);
      expect(
        File(saved.jsonPath).readAsStringSync(),
        contains('"measured": true'),
      );

      await controller().share(saved);
      expect(shared.single.paths, hasLength(3));
    });

    test('ignored pings are timeouts, not hangs', () async {
      await setUpBridge(echoEnabled: false);
      await controller().start(DebugSource.fake);
      await until(() => (state().report?.echo?.timeouts ?? 0) >= 1);
      await controller().stop();
      final echo = state().report!.echo!;
      expect(echo.answered, 0);
      expect(echo.timeouts, greaterThanOrEqualTo(1));
      expect(state().saved!.echoCsvPath, isNotNull);
    });

    test(
      'a bridge without FF15 runs without a round trip and says so',
      () async {
        await setUpBridge(
          device: const FakeDevice(
            id: fakeBridgeDeviceId,
            name: wmrBridgeDeviceName,
            services: [
              BleServiceInfo(
                uuid: wmrBridgeServiceUuid,
                characteristicUuids: [
                  wmrBridgeStreamCharUuid,
                  wmrBridgeDecodedCharUuid,
                  wmrBridgeBatchedCharUuid,
                ],
              ),
            ],
          ),
        );
        await controller().start(DebugSource.fake);
        expect(state().stage, LatencyStage.running);
        expect(state().echoNote, contains('no FF15'));
        await controller().stop();
        expect(state().report!.echo, isNull);
        expect(state().saved!.echoCsvPath, isNull);
        expect(transport.writes, isEmpty);
      },
    );

    test('switched off: no FF15 traffic at all', () async {
      await setUpBridge();
      controller().setEchoEnabled(false);
      await controller().start(DebugSource.fake);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await controller().stop();
      expect(transport.writes, isEmpty);
      expect(transport.cccLog.where((l) => l.contains('ff15')), isEmpty);
      expect(state().report!.echo, isNull);
      expect(state().echoEnabled, isFalse);
    });
  });
}
