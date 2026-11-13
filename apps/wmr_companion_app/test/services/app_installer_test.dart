import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/app_installer.dart';

const _channel = MethodChannel(AppInstaller.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
  });

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) {
          calls.add(call);
          return handler(call);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }

  test('uses the app updater channel', () {
    expect(AppInstaller.channelName, 'com.onyxlens.wmr_companion/app_updater');
  });

  test('canRequestPackageInstalls forwards the native answer', () async {
    mockChannel((_) async => true);

    expect(await AppInstaller().canRequestPackageInstalls(), isTrue);
    expect(calls.single.method, 'canRequestPackageInstalls');
  });

  test('canRequestPackageInstalls fails closed', () async {
    mockChannel((_) async => null);

    expect(await AppInstaller().canRequestPackageInstalls(), isFalse);
  });

  test('a missing platform reports no install permission', () async {
    expect(await AppInstaller().canRequestPackageInstalls(), isFalse);
  });

  test('openUnknownSourcesSettings reaches the activity', () async {
    mockChannel((_) async => null);

    await AppInstaller().openUnknownSourcesSettings();

    expect(calls.single.method, 'openUnknownSourcesSettings');
  });

  test('openUnknownSourcesSettings is a no-op without a platform', () async {
    await AppInstaller().openUnknownSourcesSettings();
  });

  test('installApk passes the downloaded path to PackageInstaller', () async {
    mockChannel((_) async => null);

    await AppInstaller().installApk('/data/user/0/app/update.apk');

    expect(calls.single.method, 'installApk');
    expect(calls.single.arguments, {'path': '/data/user/0/app/update.apk'});
  });

  test(
    'installApk rejects an empty path without calling the platform',
    () async {
      mockChannel((_) async => null);

      await expectLater(AppInstaller().installApk('  '), throwsArgumentError);
      expect(calls, isEmpty);
    },
  );

  test('a cancelled install surfaces the platform error', () async {
    mockChannel(
      (_) async => throw PlatformException(
        code: 'install_cancelled',
        message: 'the install was cancelled',
      ),
    );

    await expectLater(
      AppInstaller().installApk('/tmp/update.apk'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'install_cancelled',
        ),
      ),
    );
  });
}
