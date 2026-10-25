import 'package:test/test.dart';
import 'package:wmr_tracking/wmr_tracking.dart';

void main() {
  test('the first sample establishes the offset', () {
    final aligner = SourceClockAligner();

    final host = aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000);

    expect(host, 5000);
    expect(aligner.offsetNs, 4000);
  });

  test('jitter is low-pass filtered, not copied into the timestamp', () {
    final aligner = SourceClockAligner(smoothing: 0.25);
    aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000);

    final host = aligner.align(sourceTimeNs: 2000, hostTimeNs: 6030);

    expect(host, 2000 + 4008);
    expect(aligner.offsetNs, 4008);
  });

  test('an arrival outlier is rejected but still mapped', () {
    final aligner = SourceClockAligner(
      maxCorrection: const Duration(milliseconds: 50),
    );
    aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000000);

    final host = aligner.align(sourceTimeNs: 2000000, hostTimeNs: 62000000);

    expect(host, 2000000 + 4999000);
    expect(aligner.offsetNs, 4999000);
  });

  test('a delayed frame is mapped with the existing offset', () {
    final aligner = SourceClockAligner();
    aligner.align(sourceTimeNs: 2000000000, hostTimeNs: 5000000000);

    final host = aligner.align(
      sourceTimeNs: 1999900000,
      hostTimeNs: 5000500000,
    );

    expect(host, 1999900000 + 3000000000);
    expect(aligner.offsetNs, 3000000000);
  });

  test('a source clock reset beyond the threshold rebases', () {
    final aligner = SourceClockAligner();
    aligner.align(sourceTimeNs: 2000000000, hostTimeNs: 5000000000);

    final host = aligner.align(sourceTimeNs: 1000, hostTimeNs: 5500000000);

    expect(host, 5500000000);
    expect(aligner.offsetNs, 5499999000);
  });

  test('reset forgets the offset', () {
    final aligner = SourceClockAligner();
    aligner.align(sourceTimeNs: 1000, hostTimeNs: 5000);
    aligner.reset();

    expect(aligner.offsetNs, isNull);
    expect(aligner.align(sourceTimeNs: 1000, hostTimeNs: 9000), 9000);
  });
}
