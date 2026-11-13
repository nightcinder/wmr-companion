import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/app_release_checker.dart';

const _apkName = 'wmr-companion-0.3.25-unified-arm64-v8a.apk';
const _tag = 'v0.3.25';
const _apkUrl =
    'https://github.com/nightcinder/wmr-companion/releases/download/'
    '$_tag/$_apkName';
const _sumsUrl =
    'https://github.com/nightcinder/wmr-companion/releases/download/'
    '$_tag/SHA256SUMS';

final _apkBytes = Uint8List.fromList(List.generate(4096, (i) => i % 251));
final _apkDigest = sha256.convert(_apkBytes).toString();

String _releaseDocument({
  String tag = _tag,
  bool apk = true,
  bool sums = true,
  String apkUrl = _apkUrl,
  String? apkName = _apkName,
}) {
  return jsonEncode({
    'tag_name': tag,
    'assets': [
      if (apk) {'name': apkName, 'browser_download_url': apkUrl},
      if (sums) {'name': 'SHA256SUMS', 'browser_download_url': _sumsUrl},
    ],
  });
}

void main() {
  late Directory temp;
  late Map<String, String?> responses;
  late int fetches;
  late DateTime now;

  AppReleaseChecker checker() => AppReleaseChecker(
    fetch: (uri) async {
      fetches++;
      return responses[uri.toString()];
    },
    download: (uri, destination) async => destination.writeAsBytes(_apkBytes),
    tempDirectory: () async => temp,
    clock: () => now,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('app_release_checker_test');
    responses = {};
    fetches = 0;
    now = DateTime.utc(2026, 11, 13, 12);
    responses[appLatestReleaseUrl] = _releaseDocument();
    responses[_sumsUrl] = '${'0' * 64}  other.apk\n$_apkDigest  *$_apkName\n';
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('AppRelease.parse', () {
    test('reads the tag, unified APK and checksum asset', () {
      final release = AppRelease.parse(_releaseDocument());

      expect(release, isNotNull);
      expect(release!.tagName, _tag);
      expect(release.version.major, 0);
      expect(release.version.minor, 3);
      expect(release.version.patch, 25);
      expect(release.apkName, _apkName);
      expect(release.apkUrl.toString(), _apkUrl);
      expect(release.checksumUrl.toString(), _sumsUrl);
    });

    test('fails closed without the unified arm64-v8a APK', () {
      expect(AppRelease.parse(_releaseDocument(apk: false)), isNull);
    });

    test('fails closed without SHA256SUMS', () {
      expect(AppRelease.parse(_releaseDocument(sums: false)), isNull);
    });

    test('fails closed on an APK for another ABI', () {
      expect(
        AppRelease.parse(
          _releaseDocument(
            apkName: 'wmr-companion-0.3.25-viture-arm64-v8a.apk',
          ),
        ),
        isNull,
      );
    });

    test('fails closed when two unified APKs make the choice ambiguous', () {
      final document = jsonDecode(_releaseDocument()) as Map<String, Object?>;
      (document['assets'] as List).add({
        'name': 'wmr-companion-0.3.25-unified-arm64-v8a.apk',
        'browser_download_url': _apkUrl,
      });

      expect(AppRelease.parse(jsonEncode(document)), isNull);
    });

    test('fails closed on a non-https asset URL', () {
      expect(
        AppRelease.parse(
          _releaseDocument(apkUrl: _apkUrl.replaceFirst('https://', 'http://')),
        ),
        isNull,
      );
    });

    test('fails closed on a malformed tag or document', () {
      expect(AppRelease.parse(_releaseDocument(tag: 'nightly')), isNull);
      expect(AppRelease.parse('not json'), isNull);
      expect(AppRelease.parse('[]'), isNull);
    });
  });

  group('AppReleaseChecker.latest', () {
    test('returns the parsed release', () async {
      final release = await checker().latest();

      expect(release?.version.patch, 25);
    });

    test('serves repeat calls from the cache until it expires', () async {
      final subject = checker();

      await subject.latest();
      await subject.latest();
      expect(fetches, 1);

      now = now.add(const Duration(hours: 2));
      await subject.latest();
      expect(fetches, 2);
    });

    test(
      'returns null instead of throwing when GitHub is unreachable',
      () async {
        final subject = AppReleaseChecker(
          fetch: (uri) async => throw const SocketException('offline'),
          tempDirectory: () async => temp,
        );

        expect(await subject.latest(), isNull);
      },
    );

    test('returns null when the response is not 200', () async {
      responses[appLatestReleaseUrl] = null;

      expect(await checker().latest(), isNull);
    });

    test('returns null for a release missing SHA256SUMS', () async {
      responses[appLatestReleaseUrl] = _releaseDocument(sums: false);

      expect(await checker().latest(), isNull);
    });
  });

  group('AppReleaseChecker.downloadVerified', () {
    test('writes the APK and accepts a matching digest', () async {
      final release = (await checker().latest())!;

      final file = await checker().downloadVerified(release);

      expect(await file.exists(), isTrue);
      expect(file.path, endsWith('/$_apkName'));
      expect(await file.readAsBytes(), _apkBytes);
      expect(await file.parent.list().length, 1);
    });

    test('fails closed and deletes the APK on a digest mismatch', () async {
      responses[_sumsUrl] = '${'1' * 64}  $_apkName\n';
      final release = (await checker().latest())!;

      await expectLater(
        checker().downloadVerified(release),
        throwsA(isA<AppReleaseException>()),
      );
      final directory = Directory('${temp.path}/wmr-companion-update');
      expect(await directory.list().toList(), isEmpty);
    });

    test('fails closed when SHA256SUMS has no entry for the APK', () async {
      responses[_sumsUrl] = '${'1' * 64}  some-other.apk\n';
      final release = (await checker().latest())!;

      await expectLater(
        checker().downloadVerified(release),
        throwsA(isA<AppReleaseException>()),
      );
      expect(
        await Directory('${temp.path}/wmr-companion-update').list().toList(),
        isEmpty,
      );
    });

    test('fails closed when SHA256SUMS cannot be downloaded', () async {
      final release = (await checker().latest())!;
      responses[_sumsUrl] = null;

      await expectLater(
        checker().downloadVerified(release),
        throwsA(isA<AppReleaseException>()),
      );
    });
  });

  group('AppReleaseChecker.downloadAndInstall', () {
    test('hands the verified APK to the installer', () async {
      final release = (await checker().latest())!;
      String? installed;

      final file = await checker().downloadAndInstall(
        release,
        (apkPath) async => installed = apkPath,
      );

      expect(installed, file.path);
      expect(await File(installed!).readAsBytes(), _apkBytes);
    });

    test('never calls the installer when the digest does not match', () async {
      responses[_sumsUrl] = '${'2' * 64}  $_apkName\n';
      final release = (await checker().latest())!;
      var installs = 0;

      await expectLater(
        checker().downloadAndInstall(release, (apkPath) async => installs++),
        throwsA(isA<AppReleaseException>()),
      );
      expect(installs, 0);
    });
  });

  group('AppReleaseChecker.parseChecksum', () {
    test('finds the APK among text and binary entries', () {
      final document =
          '${'a' * 64}  first.apk\n'
          '${'B' * 64}  $_apkName\n'
          '${'c' * 64} *last.apk\n';

      expect(AppReleaseChecker.parseChecksum(document, _apkName), 'b' * 64);
    });

    test('returns null for no match or a truncated digest', () {
      expect(AppReleaseChecker.parseChecksum('', _apkName), isNull);
      expect(
        AppReleaseChecker.parseChecksum('${'a' * 63}  $_apkName\n', _apkName),
        isNull,
      );
    });
  });
}
