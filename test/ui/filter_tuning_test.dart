import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_companion_app/ui/debug/debug_providers.dart';
import 'package:wmr_companion_app/ui/debug/stream_settings.dart';

void main() {
  test('filter tuning clamps to the slider bounds', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(filterTuningProvider.notifier);

    n.setBeta(-1);
    expect(c.read(filterTuningProvider).beta, madgwickBetaMin);
    n.setBeta(1);
    expect(c.read(filterTuningProvider).beta, madgwickBetaMax);

    n.setMahonyKp(-1);
    expect(c.read(filterTuningProvider).mahonyKp, mahonyKpMin);
    n.setMahonyKp(100);
    expect(c.read(filterTuningProvider).mahonyKp, mahonyKpMax);

    n.setMahonyKi(-1);
    expect(c.read(filterTuningProvider).mahonyKi, mahonyKiMin);
    n.setMahonyKi(100);
    expect(c.read(filterTuningProvider).mahonyKi, mahonyKiMax);

    n.reset();
    expect(c.read(filterTuningProvider), const FilterTuning());
  });

  test('the active fake service applies tuning to both hands', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(filterTuningProvider);
    final service = await c.read(fakeServiceProvider.future);

    c.read(filterTuningProvider.notifier).setBeta(0.12);
    await Future<void>.delayed(Duration.zero);
    expect(service.pipeline(0).beta, 0.12);
    expect(service.pipeline(1).beta, 0.12);

    c.read(filterKindProvider.notifier).set(FilterKind.mahony);
    c.read(filterTuningProvider.notifier).setMahonyKp(2.5);
    c.read(filterTuningProvider.notifier).setMahonyKi(0.2);
    await Future<void>.delayed(Duration.zero);
    for (final hand in [0, 1]) {
      expect(service.pipeline(hand).kind, FilterKind.mahony);
      expect(service.pipeline(hand).mahonyKp, 2.5);
      expect(service.pipeline(hand).mahonyKi, 0.2);
    }
  });
}
