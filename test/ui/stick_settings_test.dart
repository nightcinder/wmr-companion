import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/stick_centre.dart';
import 'package:wmr_companion/services/stick_settings_store.dart';
import 'package:wmr_companion/ui/debug/stream_settings.dart';

class MemoryStickStore implements StickSettingsStore {
  MemoryStickStore([this.saved]);

  StickSettings? saved;
  int saves = 0;
  Completer<void>? loadGate;

  @override
  Future<StickSettings?> load() async {
    await loadGate?.future;
    return saved;
  }

  @override
  Future<void> save(StickSettings settings) async {
    saves++;
    saved = settings;
  }
}

const custom = StickSettings(
  config: StickConfig(deadZone: 0.2, learn: false),
  centres: [
    [0.03, 0.148],
    null,
  ],
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  ProviderContainer make(MemoryStickStore store) {
    final c = ProviderContainer(
      overrides: [
        stickSettingsStoreProvider.overrideWithValue(store),
        stickSaveDelayProvider.overrideWithValue(
          const Duration(milliseconds: 60),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('loads the saved options and centres after startup', () async {
    final c = make(MemoryStickStore(custom));
    expect(c.read(stickSettingsProvider), const StickSettings());
    await settle();
    expect(c.read(stickSettingsProvider), custom);
    expect(c.read(stickConfigProvider), custom.config);
  });

  test('a change made before the load finishes wins', () async {
    final store = MemoryStickStore(custom)..loadGate = Completer<void>();
    final c = make(store);
    c.read(stickSettingsProvider);
    c.read(stickSettingsProvider.notifier).setLearn(true);
    store.loadGate!.complete();
    await settle();
    expect(c.read(stickSettingsProvider).config.learn, isTrue);
    expect(c.read(stickSettingsProvider).centres, [null, null]);
  });

  test('saves once after a burst of changes', () async {
    final store = MemoryStickStore();
    final c = make(store);
    c.read(stickSettingsProvider);
    final n = c.read(stickSettingsProvider.notifier);
    for (var v = 0.05; v <= 0.1; v += 0.01) {
      n.setDeadZone(v);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(store.saves, 0);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.saves, 1);
    expect(store.saved!.config.deadZone, closeTo(0.1, 1e-9));
  });

  test('a learned centre is saved', () async {
    final store = MemoryStickStore();
    final c = make(store);
    c.read(stickSettingsProvider);
    c.read(stickSettingsProvider.notifier).setCentre(0, 0.03, 0.148);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.saves, 1);
    expect(store.saved!.centreFor(0), [0.03, 0.148]);
    expect(store.saved!.centreFor(1), isNull);
  });

  test('invalid and unchanged centres do not cause a write', () async {
    final store = MemoryStickStore(custom);
    final c = make(store);
    c.read(stickSettingsProvider);
    await settle();
    final n = c.read(stickSettingsProvider.notifier);
    n.setCentre(0, double.nan, 0.1);
    n.setCentre(0, 0.03, 0.148); // same as the saved one
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.saves, 0);
  });

  test('clearing a centre is saved', () async {
    final store = MemoryStickStore(custom);
    final c = make(store);
    c.read(stickSettingsProvider);
    await settle();
    c.read(stickSettingsProvider.notifier).clearCentre(0);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.saved!.centreFor(0), isNull);
  });

  test('reset saves the defaults', () async {
    final store = MemoryStickStore(custom);
    final c = make(store);
    c.read(stickSettingsProvider);
    await settle();
    c.read(stickSettingsProvider.notifier).reset();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.saved, const StickSettings());
  });

  test('disposing flushes a pending save', () async {
    final store = MemoryStickStore();
    final c = ProviderContainer(
      overrides: [stickSettingsStoreProvider.overrideWithValue(store)],
    );
    c.read(stickSettingsProvider);
    c.read(stickSettingsProvider.notifier).setCentre(1, -0.02, 0.001);
    c.dispose();
    await settle();
    expect(store.saved!.centreFor(1), [-0.02, 0.001]);
  });
}
