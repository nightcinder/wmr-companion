import 'dart:io';

import 'package:test/test.dart';

/// `wmr_companion` is the framework-agnostic facade. It must not depend on
/// Flutter, Riverpod, a platform plugin, the app, or the transports/UI built
/// on top of it.
const _forbiddenPrefixes = <String>[
  'dart:ui',
  'package:flutter/',
  'package:flutter_riverpod/',
  'package:riverpod/',
  'package:hooks_riverpod/',
  'package:universal_ble/',
  'package:path_provider/',
  'package:share_plus/',
  'package:permission_handler/',
  'package:wmr_ble/',
  'package:wmr_companion_ui/',
  'package:wmr_companion_hid_android/',
  'package:wmr_companion_app/',
];

void main() {
  test('lib/ imports no Flutter, Riverpod, plugin or higher layer', () {
    final lib = _packageLib('wmr_companion');
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
          'wmr_companion must stay framework-agnostic and below the '
          'transports/UI:\n${violations.join('\n')}',
    );
  });

  test('the public surface is only wmr_companion.dart and testing.dart', () {
    final lib = _packageLib('wmr_companion');
    final topLevel =
        lib
            .listSync()
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .where((name) => name.endsWith('.dart'))
            .toList()
          ..sort();

    expect(
      topLevel,
      ['testing.dart', 'wmr_companion.dart'],
      reason:
          'only the two documented entry points may be top-level '
          'libraries; everything else belongs under lib/src/',
    );
  });
}

/// Returns the URI of an `import`, `export` or `part` directive, or null when
/// [line] is not one.
String? _directiveUri(String line) {
  final match = RegExp(
    r'''^\s*(?:import|export|part)\s+(?:'([^']+)'|"([^"]+)")''',
  ).firstMatch(line);
  return match == null ? null : match.group(1) ?? match.group(2);
}

/// Finds this package's `lib/` directory whether the test runs from the
/// package directory or from the repository root.
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
