import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/ble/ble_transport.dart';
import 'package:wmr_companion/ble/fake_wmr_bridge.dart';
import 'package:wmr_companion/protocol/wmr_fragment.dart';
import 'package:wmr_companion/services/capture_files.dart';
import 'package:wmr_companion/services/controller_service.dart';
import 'package:wmr_companion/ui/capture/capture_providers.dart';

class _Clock implements MonotonicClock {
  int now = 5000000;

  @override
  int get nowUs => now;
}

void main() {
  late Directory dir;
  late _Clock clock;
  late StreamController<ReceivedFrame> frames;
  late ProviderContainer container;
  final shared = <String>[];

  CaptureController controller() =>
      container.read(captureControllerProvider.notifier);
  CaptureState state() => container.read(captureControllerProvider);

  Future<void> until(bool Function() test) async {
    for (var i = 0; i < 500 && !test(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(test(), isTrue);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('capture_ui');
    clock = _Clock();
    frames = StreamController<ReceivedFrame>.broadcast();
    shared.clear();
    container = ProviderContainer(
      overrides: [
        captureInputProvider.overrideWithValue(
          () => CaptureInput(frames: frames.stream, clock: clock, mtu: 517),
        ),
        captureStoreProvider.overrideWith((ref) => CaptureStore(dir)),
        captureTickProvider.overrideWithValue(const Duration(milliseconds: 1)),
        shareCaptureProvider.overrideWithValue((p) async => shared.add(p)),
      ],
    );
    container.listen(captureControllerProvider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await frames.close();
    dir.deleteSync(recursive: true);
  });

  test('guided run writes all four phases and shows per-phase stats', () async {
    controller().selectHand(wmrHandRight);
    await controller().start();
    expect(state().stage, CaptureStage.ready);
    expect(state().path, contains('right-'));

    var seq = 0;
    for (final phase in ['still', 'twist_cw', 'flip_away', 'lean_right']) {
      expect(state().phase.name, phase);
      controller().beginPhase();
      await until(() => state().stage == CaptureStage.recording);
      // 1 s of frames, one lost, then the minimum time for the phase.
      for (var i = 0; i < 10; i++) {
        seq += i == 5 ? 2 : 1;
        clock.now += 100000;
        frames.add(ReceivedFrame(syntheticFrame(wmrHandRight, seq), clock.now));
      }
      await Future<void>.delayed(Duration.zero);
      clock.now += 5000000;
      await until(() => state().canFinish);
      await controller().finishPhase();
    }

    expect(state().stage, CaptureStage.finished);
    expect(state().summaries.map((s) => s.name), [
      'still',
      'twist_cw',
      'flip_away',
      'lean_right',
    ]);
    final first = state().summaries.first.hands[wmrHandRight];
    expect(first.frames, 10);
    expect(first.missing, 1);

    final text = File(state().path!).readAsStringSync();
    final lines = text.split('\n');
    expect(lines.take(5), [
      '# wmr-capture v1',
      '# source: BLE FF11 raw stream via wmr_companion app (phone)',
      '# hand: RIGHT (as stated by the operator)',
      '# mtu: 517',
      startsWith('# started: '),
    ]);
    expect(
      lines.where((l) => l.startsWith('@begin ')).map((l) => l.split(' ')[1]),
      ['still', 'twist_cw', 'flip_away', 'lean_right'],
    );
    expect(lines.where((l) => l.startsWith('@end ')), hasLength(4));
    expect(lines.where((l) => l.startsWith('F ')), hasLength(40));
    expect(state().saved.map((c) => c.path), [state().path]);

    await controller().share(state().path!);
    expect(shared, [state().path]);
  });

  test('Finish stays disabled until the still phase has run 5 s', () async {
    await controller().start();
    controller().beginPhase();
    await until(() => state().stage == CaptureStage.recording);
    expect(state().canFinish, isFalse);
    await controller().finishPhase();
    expect(state().stage, CaptureStage.recording);
    clock.now += 5000000;
    await until(() => state().canFinish);
  });

  test('refuses to start without a connection', () async {
    final c = ProviderContainer(
      overrides: [
        captureInputProvider.overrideWithValue(() => null),
        captureStoreProvider.overrideWith((ref) => CaptureStore(dir)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(captureControllerProvider, (_, _) {});
    await c.read(captureControllerProvider.notifier).start();
    expect(c.read(captureControllerProvider).error, isNotNull);
    expect(c.read(captureControllerProvider).stage, CaptureStage.setup);
    expect(dir.listSync(), isEmpty);
  });
}
