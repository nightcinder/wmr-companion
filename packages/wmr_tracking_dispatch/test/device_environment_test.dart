import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_tracking_dispatch/wmr_tracking_dispatch.dart';

/// A headset the vendor table has never seen, with names and class codes the
/// app does not interpret.
const _unknownEnvironment = {
  'usb': {
    'host_available': true,
    'devices': [
      {
        'vendor_id': 0xFFFF,
        'product_id': 0xEEEE,
        'device_name': '/dev/bus/usb/001/002',
        'manufacturer': 'URXR',
        'product': 'One',
        'interfaces': [
          {'class': 0xFF, 'subclass': 0x42, 'protocol': 0x99},
        ],
      },
    ],
  },
  'displays': {
    'items': [
      {
        'id': 7,
        'type': 'type_99',
        'name': 'URXR One',
        'width': 2328,
        'height': 1728,
        'refresh_rate_hz': 90.0,
      },
    ],
  },
  'xr_features': [
    {'name': 'vendor.urxr.spatial', 'present': false},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('serializes unknown USB, display and XR feature fixtures', () {
    final snapshot = DeviceEnvironmentSnapshot.fromMap(
      _unknownEnvironment,
      capturedAt: DateTime.utc(2026, 11, 9, 12),
    );

    final device = snapshot.usbDevices.single;
    expect(device.vendorId, 0xFFFF);
    expect(device.productId, 0xEEEE);
    expect(device.deviceName, '/dev/bus/usb/001/002');
    expect(device.manufacturerName, 'URXR');
    expect(device.productName, 'One');
    final interface = device.interfaces.single;
    expect(interface.interfaceClass, 0xFF);
    expect(interface.interfaceSubclass, 0x42);
    expect(interface.interfaceProtocol, 0x99);

    final display = snapshot.displays.single;
    expect(display.type, 'type_99');
    expect(display.isExternal, isFalse);
    expect(display.name, 'URXR One');

    final feature = snapshot.xrFeatures.single;
    expect(feature.name, 'vendor.urxr.spatial');
    expect(feature.present, isFalse);

    final json = snapshot.toJson();
    expect(json['format'], 'wmr-device-environment/1');
    expect(json['captured_at'], '2026-11-09T12:00:00.000Z');
    expect(
      ((json['usb'] as Map)['devices'] as List).single,
      containsPair('vendor_id', 0xFFFF),
    );
    expect(
      ((json['displays'] as Map)['items'] as List).single,
      containsPair('type', 'type_99'),
    );
    expect(
      (json['xr_features'] as List).single,
      containsPair('name', 'vendor.urxr.spatial'),
    );

    final roundTripped = DeviceEnvironmentSnapshot.fromMap(
      json,
      capturedAt: DateTime.utc(2026, 11, 9, 12),
    );
    expect(roundTripped.toJson(), json);
  });

  test('counts external displays without dropping other classifications', () {
    final snapshot = DeviceEnvironmentSnapshot.fromMap({
      'usb': {'host_available': false, 'devices': []},
      'displays': {
        'items': [
          {'id': 1, 'type': 'external'},
          {'id': 2, 'type': 'builtIn'},
          {'id': 3, 'type': 'type_42'},
        ],
      },
      'xr_features': [],
    }, capturedAt: DateTime.utc(2026, 11, 9, 12));

    expect(snapshot.externalDisplays.map((d) => d.id), [1]);
    expect(snapshot.displays, hasLength(3));
    expect((snapshot.toJson()['displays'] as Map)['external_count'], 1);
  });

  test('the platform probe parses the native map', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(PlatformGlassesDetector.channelName),
          (call) async {
            calls.add(call);
            return _unknownEnvironment;
          },
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(PlatformGlassesDetector.channelName),
            null,
          );
    });

    final snapshot = await const PlatformDeviceEnvironmentProbe().probe();

    expect(calls.single.method, 'deviceEnvironment');
    expect(snapshot.status, DeviceEnvironmentProbeStatus.ok);
    expect(snapshot.usbDevices.single.productName, 'One');
    expect(snapshot.displays.single.type, 'type_99');
    expect(snapshot.xrFeatures.single.name, 'vendor.urxr.spatial');
  });

  test('a missing plugin reports an unsupported probe', () async {
    final snapshot = await const PlatformDeviceEnvironmentProbe().probe();

    expect(snapshot.status, DeviceEnvironmentProbeStatus.unsupported);
    expect(snapshot.reason, DeviceEnvironmentReason.probeUnavailable);
    expect(snapshot.usbDevices, isEmpty);
    expect(snapshot.displays, isEmpty);
  });

  test('a non-map probe result is a failed probe, not an exception', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(PlatformGlassesDetector.channelName),
          (call) async => 'not-a-map',
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(PlatformGlassesDetector.channelName),
            null,
          );
    });

    final snapshot = await const PlatformDeviceEnvironmentProbe().probe();

    expect(snapshot.status, DeviceEnvironmentProbeStatus.failed);
    expect(snapshot.reason, DeviceEnvironmentReason.probeFailed);
  });
}
