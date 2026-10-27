import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flavor configuration checks for ONY-271 and ONY-355. These read the Gradle
/// and shell sources because the Android builds themselves are exercised by
/// `tool/test_flavor_wiring.sh`.
void main() {
  final appBuild = File('android/app/build.gradle.kts').readAsStringSync();
  final settings = File('android/settings.gradle.kts').readAsStringSync();
  final buildFlavor = File('tool/build_flavor.sh').readAsStringSync();

  group('Android build flavors', () {
    test(
      'declares base, viture, xreal and unified in one vendor dimension',
      () {
        expect(appBuild, contains('flavorDimensions += "vendor"'));
        for (final flavor in ['base', 'viture', 'xreal', 'unified']) {
          expect(
            appBuild,
            contains('create("$flavor")'),
            reason: 'missing $flavor product flavor',
          );
        }
      },
    );

    test('links each Unity module only from its own flavor', () {
      expect(
        appBuild,
        contains('"vitureImplementation"(project(":unityLibraryViture"))'),
      );
      expect(
        appBuild,
        contains('"xrealImplementation"(project(":unityLibraryXreal"))'),
      );
      expect(
        appBuild,
        contains('"unifiedImplementation"(project(":unityLibraryUnified"))'),
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
      expect(settings, contains('unity/unified/unityLibrary'));
      expect(settings, contains('filterValues { it.isDirectory }'));
      expect(settings, contains('include(module)'));
    });

    test('rejects incompatible Unity exports with a clear message', () {
      expect(settings, contains('presentUnityLibraries.size > 1'));
      expect(settings, contains('Cannot link both Unity libraries'));
      expect(
        settings,
        contains('cannot be combined with per-vendor Unity exports'),
      );
      expect(appBuild, contains('Cannot link multiple unityLibrary modules'));
    });

    test('includes the nested XR manifest library Unity exports', () {
      // Unity references it as `:unityLibrary:xrmanifest.androidlib`; the
      // installer remaps that to the included module, so settings must register
      // the child project at the export's directory (ONY-388).
      expect(settings, contains('xrmanifest.androidlib'));
      expect(
        settings,
        contains(r'include("$module:xrmanifest.androidlib")'),
      );
      expect(
        settings,
        contains(r'project("$module:xrmanifest.androidlib").projectDir'),
      );
    });

    test('unified requires API 33 for the VITURE 0.9.0 AAR', () {
      // VitureUnityXR.aar declares minSdk 33; an export with it cannot merge
      // into a lower minSdk (ONY-388).
      final match = RegExp(
        r'create\("unified"\)\s*\{(.*?)\}',
        dotAll: true,
      ).firstMatch(appBuild);
      expect(match, isNotNull, reason: 'missing unified product flavor');
      expect(match!.group(1), contains('minSdk = 33'));
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

    test('unified compiles every vendor adapter for runtime selection', () {
      final match = RegExp(
        r'unified\).*?defines=\((.*?)\)\s*;;',
        dotAll: true,
      ).firstMatch(buildFlavor);
      expect(match, isNotNull, reason: 'missing unified build_flavor case');
      final defines = match!.group(1)!;
      expect(defines, contains('WMR_ANDROID_XR_TRACKING=true'));
      expect(defines, contains('WMR_VITURE_TRACKING=true'));
      expect(defines, contains('WMR_XREAL_TRACKING=true'));
    });
  });
}
