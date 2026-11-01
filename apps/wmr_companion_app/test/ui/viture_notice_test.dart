import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the VITURE SDK notice ships with the app', () async {
    final text = await rootBundle.loadString('assets/notices/viture_sdk.txt');
    expect(text, contains('VITURE XR Glasses SDK for Android 2.4.1'));
    expect(text, contains('VITURE libglasses SDK License'));
    expect(text, contains('Open Source Software Notice'));
    // The notice carries the LGPL/BSD components libglasses.so links in.
    expect(text, contains('libusb'));
  });

  test('the VITURE EULA ships with the app', () async {
    final text = await rootBundle.loadString('assets/legal/eula.txt');
    // VITURE SDK agreement 2.3.1 requires both of these.
    expect(text, contains('reverse engineer'));
    expect(text, contains('indemnify'));
    expect(text, contains('VITURE, Inc.'));
  });
}
