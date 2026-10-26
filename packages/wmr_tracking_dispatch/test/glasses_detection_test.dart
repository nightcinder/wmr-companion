import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses the Kotlin detection map', () {
    final detection = GlassesDetection.fromMap({
      'vendor': 'xreal',
      'host': 'beamPro',
      'usbPermissionGranted': true,
      'detail': 'XREAL Beam Pro host',
    });

    expect(detection.vendor, GlassesVendor.xreal);
    expect(detection.host, GlassesHost.beamPro);
    expect(detection.hasVendor, isTrue);
    expect(detection.usbPermissionGranted, isTrue);
    expect(detection.reason, isNull);
  });

  test('unknown vendor and host names fail closed', () {
    final detection = GlassesDetection.fromMap({
      'vendor': 'rayneo',
      'host': 'watch',
    });

    expect(detection.vendor, GlassesVendor.none);
    expect(detection.host, GlassesHost.unknown);
    expect(detection.hasVendor, isFalse);
  });

  test('a non-map detection is a protocol error', () {
    expect(
      () => GlassesDetection.fromMap('viture'),
      throwsFormatException,
    );
  });

  test('a missing plugin reports detectorUnavailable', () async {
    const detector = PlatformGlassesDetector();
    final detection = await detector.detect();

    expect(detection.vendor, GlassesVendor.none);
    expect(detection.reason, GlassesDetectionReason.detectorUnavailable);
  });

  test('flag-off selector touches no platform channel', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(PlatformGlassesDetector.channelName),
          (call) async {
            calls.add(call);
            return null;
          },
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(PlatformGlassesDetector.channelName),
            null,
          );
    });

    final selection = await const TrackingSourceSelector(
      detector: PlatformGlassesDetector(),
      flags: TrackingSourceFlags(),
    ).select();

    expect(selection.status, TrackingSelectionStatus.none);
    expect(calls, isEmpty);
  });

  test('flag-on selector asks the native detector', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(PlatformGlassesDetector.channelName),
          (call) async {
            calls.add(call);
            return {
              'vendor': 'viture',
              'host': 'neckband',
              'usbPermissionGranted': true,
            };
          },
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(PlatformGlassesDetector.channelName),
            null,
          );
    });

    final selection = await const TrackingSourceSelector(
      detector: PlatformGlassesDetector(),
      flags: TrackingSourceFlags(viture: true),
    ).select();

    expect(calls.single.method, 'detectGlasses');
    expect(selection.detection!.vendor, GlassesVendor.viture);
    expect(selection.status, TrackingSelectionStatus.unavailable);
  });
}
