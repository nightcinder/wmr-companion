import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/domain/loss_window.dart';

void main() {
  group('LossWindow', () {
    test('reports nothing until the five-second window has filled', () {
      final w = LossWindow();
      w.add(0, 10, 0);
      expect(w.statsAt(0), isNull);
      w.add(4999999, 200, 3);
      expect(w.statsAt(4999999), isNull);
    });

    test('uses the net growth over the trailing five seconds', () {
      final w = LossWindow();
      w.add(0, 100, 5);
      w.add(2000000, 200, 15);
      w.add(5000000, 300, 35);

      final s = w.statsAt(5000000)!;
      expect(s.records, 200);
      expect(s.missing, 30);
      expect(s.spanUs, 5000000);
      expect(s.loss, closeTo(30 / 230, 1e-12));
      expect(s.loss, closeTo(0.1304347826, 1e-9));
    });

    test('0 records and 0 missing is 0 %, not NaN', () {
      final w = LossWindow();
      w.add(0, 0, 0);
      w.add(5000000, 0, 0);

      final s = w.statsAt(5000000)!;
      expect(s.records, 0);
      expect(s.missing, 0);
      expect(s.loss, 0);
    });

    test('100 % loss when nothing was received in the window', () {
      final w = LossWindow();
      w.add(0, 0, 0);
      w.add(5000000, 0, 12);

      final s = w.statsAt(5000000)!;
      expect(s.records, 0);
      expect(s.missing, 12);
      expect(s.loss, 1);
    });

    test('large counters do not overflow the expected total', () {
      final w = LossWindow();
      w.add(0, 0, 0);
      w.add(5000000, 1 << 62, 1 << 62);

      final s = w.statsAt(5000000)!;
      expect(s.records, 1 << 62);
      expect(s.missing, 1 << 62);
      expect(s.loss, closeTo(0.5, 1e-12));
    });

    test('a gap longer than the window starts over', () {
      final w = LossWindow();
      w.add(0, 10, 1);
      w.add(5000001, 20, 2);
      expect(w.statsAt(5000001), isNull);
    });

    test('stale data reports nothing', () {
      final w = LossWindow();
      w.add(0, 100, 5);
      w.add(5000000, 200, 15);
      expect(w.statsAt(10000001), isNull);
    });

    test('counters going backwards (a reset) report nothing', () {
      final w = LossWindow();
      w.add(0, 100, 30);
      w.add(5000000, 90, 5);
      expect(w.statsAt(5000000), isNull);
    });

    test('reset forgets the history', () {
      final w = LossWindow();
      w.add(0, 100, 5);
      w.add(5000000, 200, 15);
      w.reset();
      expect(w.statsAt(5000000), isNull);
      w.add(6000000, 210, 16);
      expect(w.statsAt(6000000), isNull);
    });
  });
}
