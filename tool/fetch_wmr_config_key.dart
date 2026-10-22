// Fetches Monado's WMR config XOR key and writes it as
// assets/monado/wmr_config_key.bin (gitignored, 1024 bytes).
//
// The key is Monado's `wmr_config_key.h`, Copyright 2021 Jan Schmidt,
// SPDX-License-Identifier: BSL-1.0. It is not committed to this repository;
// run this once per machine that builds the app, then rebuild.
//
//   dart run tool/fetch_wmr_config_key.dart
//   dart run tool/fetch_wmr_config_key.dart --file path/to/wmr_config_key.h
//   dart run tool/fetch_wmr_config_key.dart --url <raw URL of the header>
//
// Without options it downloads the header from Monado's GitLab. The download
// path has not been run from the build container (the host is blocked
// there); the extraction is unit tested on a synthetic header.
import 'dart:io';

import 'monado_key.dart';

const _defaultUrl =
    'https://gitlab.freedesktop.org/monado/monado/-/raw/main/'
    'src/xrt/drivers/wmr/wmr_config_key.h';
const _output = 'assets/monado/wmr_config_key.bin';

Future<String> _download(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    return String.fromCharCodes(bytes);
  } finally {
    client.close();
  }
}

Future<void> main(List<String> args) async {
  String? file;
  var url = _defaultUrl;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--file' && i + 1 < args.length) {
      file = args[++i];
    } else if (args[i] == '--url' && i + 1 < args.length) {
      url = args[++i];
    } else {
      stderr.writeln(
        'usage: dart run tool/fetch_wmr_config_key.dart '
        '[--file header.h | --url URL]',
      );
      exit(64);
    }
  }
  try {
    final text = file != null
        ? File(file).readAsStringSync()
        : await _download(url);
    final key = extractMonadoKey(text);
    File(_output)
      ..createSync(recursive: true)
      ..writeAsBytesSync(key);
    stdout.writeln('Wrote $_output (${key.length} bytes). Rebuild the app.');
  } on FormatException catch (e) {
    stderr.writeln('Could not read the key: ${e.message}');
    exit(1);
  } on Exception catch (e) {
    stderr.writeln(
      'Could not fetch the key: $e\n'
      'Download wmr_config_key.h from Monado by hand and pass --file.',
    );
    exit(1);
  }
}
