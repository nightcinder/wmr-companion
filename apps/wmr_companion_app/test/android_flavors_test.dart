import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flavor configuration checks for ONY-271. These read the Gradle and shell
/// sources because the Android builds themselves are exercised by
/// `tool/test_flavor_wiring.sh`.
void main() {
  final appBuild = File('android/app/build.gradle.kts').readAsStringSync();
  final settings = File('android/settings.gradle.kts').readAsStringSync();
  final buildFlavor = File('tool/build_flavor.sh').readAsStringSync();

  group('Android build flavors', () {
    test('declares base, viture and xreal in one vendor dimension', () {
      expect(appBuild, contains('flavorDimensions += "vendor"'));
      for (final flavor in ['base', 'viture', 'xreal']) {
        expect(
          appBuild,
          contains('create("$flavor")'),
          reason: 'missing $flavor product flavor',
        );
      }
    });

    test('links each Unity module only from its own flavor', () {
      expect(
        appBuild,
        contains('"vitureImplementation"(project(":unityLibraryViture"))'),
      );
      expect(
        appBuild,
        contains('"xrealImplementation"(project(":unityLibraryXreal"))'),
      );
      // An unconditional dependency would leak Unity into base.
      expect(
        RegExp(
          r'^\s*implementation\(project\(":unityLibrary',
          multiLine: true,
        ).hasMatch(appBuild),
        isFalse,
      );
    });

    test('includes a Unity module only when its export is present', () {
      expect(settings, contains('unity/viture/unityLibrary'));
      expect(settings, contains('unity/xreal/unityLibrary'));
      expect(settings, contains('filterValues { it.isDirectory }'));
      expect(settings, contains('include(module)'));
    });

    test('rejects both Unity exports with a clear message', () {
      expect(settings, contains('presentUnityLibraries.size > 1'));
      expect(settings, contains('Cannot link both Unity libraries'));
      expect(appBuild, contains('Cannot link both unityLibrary modules'));
    });

    test('build script passes the right --dart-define for each flavor', () {
      const flags = [
        'WMR_ANDROID_XR_TRACKING',
        'WMR_VITURE_TRACKING',
        'WMR_XREAL_TRACKING',
      ];
      for (final flag in flags) {
        expect(buildFlavor, contains('--dart-define=$flag='));
      }
      expect(buildFlavor, contains(r'--flavor "$flavor"'));
      expect(buildFlavor, contains('--dart-define=WMR_VITURE_TRACKING=true'));
      expect(buildFlavor, contains('--dart-define=WMR_XREAL_TRACKING=true'));
    });
  });
}
