import 'package:test/test.dart';
import 'package:wmr_core/services/controller_service.dart';

void main() {
  group('DecodedHandStats.cumulativeLoss', () {
    test('is 0 % when nothing was received or expected', () {
      expect(const DecodedHandStats().cumulativeLoss, 0);
    });

    test('is 100 % when every expected report was missing', () {
      const stats = DecodedHandStats(records: 0, missingFromTicks: 7);
      expect(stats.cumulativeLoss, 1);
    });

    test('is missing over received plus missing', () {
      const stats = DecodedHandStats(records: 90, missingFromTicks: 10);
      expect(stats.cumulativeLoss, closeTo(0.1, 1e-12));
    });

    test('does not overflow near the integer limit', () {
      const stats = DecodedHandStats(
        records: 1 << 62,
        missingFromTicks: 1 << 62,
      );
      expect(stats.cumulativeLoss, closeTo(0.5, 1e-12));
    });
  });
}
