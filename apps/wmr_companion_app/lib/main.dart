import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The release APK bundles VITURE's libglasses.so, so the SDK's licence and
  // third-party notice must travel with it. Surfacing them on the licence
  // page is how the app reproduces the notice (ONY-740).
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/notices/viture_sdk.txt');
    yield LicenseEntryWithLineBreaks(const [
      'VITURE XR Glasses SDK for Android 2.4.1',
    ], text);
  });
  runApp(const ProviderScope(child: WmrCompanionApp()));
}
