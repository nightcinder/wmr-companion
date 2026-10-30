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
    test('declares only base and unified in one vendor dimension', () {
      expect(appBuild, contains('flavorDimensions += "vendor"'));
      for (final flavor in ['base', 'unified']) {
        expect(
          appBuild,
          contains('create("$flavor")'),
          reason: 'missing $flavor product flavor',
        );
      }
      // The per-vendor flavors are retired (ONY-565); only unified ships.
      for (final retired in ['viture', 'xreal']) {
        expect(
          appBuild,
          isNot(contains('create("$retired")')),
          reason: 'retired $retired flavor is still declared',
        );
      }
    });

    test('links the unified Unity module only from the unified flavor', () {
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
      for (final retired in ['unityLibraryViture', 'unityLibraryXreal']) {
        expect(appBuild, isNot(contains(retired)));
      }
    });

    test(
      'includes the unified Unity module only when its export is present',
      () {
        expect(settings, contains('unity/unified/unityLibrary'));
        expect(settings, contains('unifiedUnityLibrary.isDirectory'));
        expect(settings, contains('include(module)'));
        for (final retired in ['unity/viture', 'unity/xreal']) {
          expect(settings, isNot(contains('file("$retired/unityLibrary")')));
        }
      },
    );

    test('rejects a leftover per-vendor export', () {
      // ONY-565 retired the per-vendor exports; a stale one must fail loudly
      // instead of sitting unused in the gitignored unity directory.
      expect(settings, contains('retired per-vendor Unity export'));
      expect(settings, contains('listOf("viture", "xreal")'));
    });

    test('includes the nested XR manifest library Unity exports', () {
      // Unity references it as `:unityLibrary:xrmanifest.androidlib`; the
      // installer remaps that to the included module, so settings must register
      // the child project at the export's directory (ONY-388).
      expect(settings, contains('xrmanifest.androidlib'));
      expect(settings, contains(r'include("$module:xrmanifest.androidlib")'));
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
      // Only base and unified survive (ONY-565).
      expect(buildFlavor, contains(r'{base|unified}'));
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

  group('Release signing', () {
    final buildTypes = RegExp(
      r'buildTypes \{(.*?)\n    \}',
      dotAll: true,
    ).firstMatch(appBuild)?.group(1);

    test('release uses the project signing config, never the debug key', () {
      expect(buildTypes, isNotNull, reason: 'missing buildTypes block');
      final release = RegExp(
        r'release \{(.*?)\}',
        dotAll: true,
      ).firstMatch(buildTypes!)?.group(1);
      expect(release, isNotNull, reason: 'missing release build type');
      expect(release, contains('signingConfigs.findByName("release")'));
      expect(
        release,
        isNot(contains('signingConfigs.getByName("debug")')),
        reason: 'release must not fall back to the debug key',
      );
    });

    test('debug builds keep the Android debug key', () {
      final debug = RegExp(
        r'debug \{(.*?)\}',
        dotAll: true,
      ).firstMatch(buildTypes!)?.group(1);
      expect(debug, isNotNull, reason: 'missing debug build type');
      expect(debug, contains('signingConfigs.getByName("debug")'));
    });

    test('reads key.properties and the WMR_RELEASE_* environment', () {
      expect(appBuild, contains('rootProject.file("key.properties")'));
      for (final variable in [
        'WMR_RELEASE_STORE_FILE',
        'WMR_RELEASE_STORE_PASSWORD',
        'WMR_RELEASE_KEY_ALIAS',
        'WMR_RELEASE_KEY_PASSWORD',
      ]) {
        expect(appBuild, contains(variable));
      }
    });

    test('refuses a release build without signing properties', () {
      expect(appBuild, contains('Release signing is not configured'));
      expect(appBuild, contains('gradle.taskGraph.whenReady'));
    });
  });
}
