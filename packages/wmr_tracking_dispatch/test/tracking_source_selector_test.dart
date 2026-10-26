import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_tracking/wmr_tracking.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';

class _FakeDetector implements GlassesDetector {
  _FakeDetector(this.result);

  GlassesDetection result;
  int calls = 0;
  Object? throwError;

  @override
  Future<GlassesDetection> detect() async {
    calls++;
    if (throwError != null) throw throwError!;
    return result;
  }
}

class _ThrowOnStartSource extends FakeTrackingSource {
  @override
  Future<void> start() async {
    throw const TrackingException(
      TrackingExceptionKind.permissionDenied,
      'camera denied',
    );
  }
}

TrackingSourceFlags flags({
  bool viture = false,
  bool xreal = false,
  bool androidXr = false,
}) => TrackingSourceFlags(
  viture: viture,
  xreal: xreal,
  androidXr: androidXr,
);

const _viture = GlassesDetection(
  vendor: GlassesVendor.viture,
  host: GlassesHost.neckband,
  usbPermissionGranted: true,
);

const _xreal = GlassesDetection(
  vendor: GlassesVendor.xreal,
  host: GlassesHost.beamPro,
  usbPermissionGranted: true,
);

void main() {
  test('all flags off returns none without calling the detector', () async {
    final detector = _FakeDetector(_viture);
    final selector = TrackingSourceSelector(
      detector: detector,
      flags: flags(),
      vitureSource: () async => FakeTrackingSource(),
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.none);
    expect(selection.source, isNull);
    expect(detector.calls, 0);
  });

  test('detected VITURE with its flag on attaches the VITURE source', () async {
    final detector = _FakeDetector(_viture);
    final source = FakeTrackingSource();
    final selector = TrackingSourceSelector(
      detector: detector,
      flags: flags(viture: true),
      vitureSource: () async => source,
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.attached);
    expect(selection.source, same(source));
    expect(selection.detection!.vendor, GlassesVendor.viture);
    expect(source.started, isTrue);
  });

  test('detected XREAL with its flag on attaches the XREAL source', () async {
    final detector = _FakeDetector(_xreal);
    final source = FakeTrackingSource();
    final selector = TrackingSourceSelector(
      detector: detector,
      flags: flags(xreal: true),
      xrealSource: () async => source,
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.attached);
    expect(selection.source, same(source));
  });

  test('detected Android XR attaches the Android XR source', () async {
    final detector = _FakeDetector(
      const GlassesDetection(
        vendor: GlassesVendor.androidXr,
        host: GlassesHost.unknown,
        usbPermissionGranted: true,
      ),
    );
    final source = FakeTrackingSource();
    final selector = TrackingSourceSelector(
      detector: detector,
      flags: flags(androidXr: true),
      androidXrSource: () async => source,
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.attached);
    expect(selection.source, same(source));
  });

  test('detected vendor with its flag off reports unsupported', () async {
    final selector = TrackingSourceSelector(
      detector: _FakeDetector(_viture),
      flags: flags(xreal: true),
      vitureSource: () async => FakeTrackingSource(),
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.unsupported);
    expect(selection.source, isNull);
    expect(selection.message, contains('does not enable'));
  });

  test('both USB vendors fail closed as none with a reason', () async {
    final detector = _FakeDetector(
      const GlassesDetection(
        vendor: GlassesVendor.none,
        host: GlassesHost.phone,
        usbPermissionGranted: true,
        reason: GlassesDetectionReason.usbAmbiguous,
      ),
    );
    final selector = TrackingSourceSelector(
      detector: detector,
      flags: flags(viture: true, xreal: true),
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.none);
    expect(selection.message, contains('refusing to guess'));
  });

  test('permission denied detection is reported as none with a reason', () async {
    final selector = TrackingSourceSelector(
      detector: _FakeDetector(
        const GlassesDetection(
          vendor: GlassesVendor.none,
          host: GlassesHost.phone,
          reason: GlassesDetectionReason.usbPermissionDenied,
        ),
      ),
      flags: flags(viture: true),
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.none);
    expect(selection.message, contains('USB access was denied'));
  });

  test('missing factory reports unavailable', () async {
    final selector = TrackingSourceSelector(
      detector: _FakeDetector(_viture),
      flags: flags(viture: true),
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.unavailable);
  });

  test('a factory returning null reports unavailable', () async {
    final selector = TrackingSourceSelector(
      detector: _FakeDetector(_viture),
      flags: flags(viture: true),
      vitureSource: () async => null,
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.unavailable);
    expect(selection.message, contains('not available'));
  });

  test('a detector exception reports unavailable', () async {
    final detector = _FakeDetector(_viture)..throwError = StateError('boom');
    final selector = TrackingSourceSelector(
      detector: detector,
      flags: flags(viture: true),
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.unavailable);
    expect(selection.message, contains('boom'));
  });

  test('a start permission denial is typed and the source is disposed', () async {
    final source = _ThrowOnStartSource();
    final selector = TrackingSourceSelector(
      detector: _FakeDetector(_viture),
      flags: flags(viture: true),
      vitureSource: () async => source,
    );

    final selection = await selector.select();

    expect(selection.status, TrackingSelectionStatus.permissionDenied);
    expect(selection.message, 'camera denied');
    expect(source.disposed, isTrue);
  });
}
