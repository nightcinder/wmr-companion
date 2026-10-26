import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `wmr_tracking_xreal` is an optional platform plugin below the facade.
/// It may use Flutter services and `wmr_tracking`, but not Riverpod, the BLE
/// stack, core internals, the facade, UI widgets or the app.
const _forbiddenPrefixes = <String>[
  'dart:ui',
  'package:flutter_riverpod/',
  'package:riverpod/',
  'package:hooks_riverpod/',
  'package:wmr_core/',
  'package:wmr_companion/',
  'package:wmr_ble/',
  'package:wmr_ws/',
  'package:wmr_companion_ui/',
  'package:wmr_companion_hid_android/',
  'package:wmr_companion_app/',
  'package:wmr_tracking_android_xr/',
  'package:universal_ble/',
  'package:path_provider/',
  'package:share_plus/',
  'package:permission_handler/',
];

void main() {
  test('lib/ imports no Riverpod, core internals, facade or transport', () {
    final lib = _packageLib('wmr_tracking_xreal');
    final files =
        lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: 'no Dart sources found in ${lib.path}');

    final violations = <String>[];
    for (final file in files) {
      final relative = file.path.substring(lib.path.length + 1);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final uri = _directiveUri(lines[i]);
        if (uri == null) continue;
        for (final prefix in _forbiddenPrefixes) {
          if (uri.startsWith(prefix)) {
            violations.add('$relative:${i + 1}: $uri');
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'wmr_tracking_xreal must stay an optional plugin below the '
          'facade:\n${violations.join('\n')}',
    );
  });
}

String? _directiveUri(String line) {
  final match = RegExp(
    r'''^\s*(?:import|export|part)\s+(?:'([^']+)'|"([^"]+)")''',
  ).firstMatch(line);
  return match == null ? null : match.group(1) ?? match.group(2);
}

Directory _packageLib(String name) {
  final cwd = Directory.current.absolute;
  final candidates = <Directory>[cwd, Directory('${cwd.path}/packages/$name')];
  for (final candidate in candidates) {
    final pubspec = File('${candidate.path}/pubspec.yaml');
    if (pubspec.existsSync() && _packageName(pubspec) == name) {
      return Directory('${candidate.path}/lib');
    }
  }
  throw StateError(
    'cannot find package $name from ${cwd.path}; run this test from the '
    'package directory or the repository root',
  );
}

String? _packageName(File pubspec) {
  for (final line in pubspec.readAsLinesSync()) {
    final match = RegExp(r'^name:\s*(\S+)').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}
