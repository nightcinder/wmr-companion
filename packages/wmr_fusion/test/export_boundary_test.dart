import 'dart:io';

import 'package:test/test.dart';

/// `wmr_fusion` is the zero-dependency base of the package graph. Its library
/// code may only use `dart:` libraries and its own relative imports; it must
/// never pull in Flutter, a plugin or any other package.
const _forbiddenPrefixes = <String>['package:'];

void main() {
  test('lib/ has no package imports (wmr_fusion stays zero-dependency)', () {
    final lib = _packageLib('wmr_fusion');
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
          'wmr_fusion must stay pure Dart with no package dependencies:\n'
          '${violations.join('\n')}',
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
