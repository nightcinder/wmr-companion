import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wmr_core/protocol/firmware_version.dart';

/// The GitHub Releases endpoint for the latest wmr-companion release.
const String appLatestReleaseUrl =
    'https://api.github.com/repos/nightcinder/wmr-companion/releases/latest';

/// Matches the unified tester APK, for example
/// `wmr-companion-0.3.25-unified-arm64-v8a.apk`.
final RegExp unifiedApkPattern = RegExp(
  r'^wmr-companion-.+-unified-arm64-v8a\.apk$',
);

/// One published wmr-companion release with the assets the in-app updater
/// needs: the unified arm64-v8a APK and the `SHA256SUMS` file covering it.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tagName,
    required this.apkName,
    required this.apkUrl,
    required this.checksumUrl,
  });

  /// The release version, parsed from `tag_name`.
  final WmrSemanticVersion version;

  /// The raw release tag, for example `v0.3.25`.
  final String tagName;

  /// The APK asset's file name, as listed in `SHA256SUMS`.
  final String apkName;

  final Uri apkUrl;
  final Uri checksumUrl;

  /// Parses a GitHub `releases/latest` response.
  ///
  /// Returns null unless the document names a version tag, exactly one
  /// unified-arm64-v8a APK, and `SHA256SUMS`, each with an `https` download
  /// URL. Installs are fail-closed: a release missing any of those cannot be
  /// verified and is treated as "no update".
  static AppRelease? parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    final tag = decoded['tag_name'];
    if (tag is! String) return null;
    final version = WmrSemanticVersion.tryParse(tag);
    if (version == null) return null;

    final assets = decoded['assets'];
    if (assets is! List) return null;

    String? apkName;
    Uri? apkUrl;
    Uri? checksumUrl;
    var apkCount = 0;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is! String || url is! String) continue;
      final uri = _httpsUri(url);
      if (uri == null) continue;
      if (name == 'SHA256SUMS') {
        checksumUrl = uri;
      } else if (unifiedApkPattern.hasMatch(name)) {
        apkCount++;
        apkName = name;
        apkUrl = uri;
      }
    }
    if (apkCount != 1 || apkName == null || apkUrl == null) return null;
    if (checksumUrl == null) return null;

    return AppRelease(
      version: version,
      tagName: tag,
      apkName: apkName,
      apkUrl: apkUrl,
      checksumUrl: checksumUrl,
    );
  }

  static Uri? _httpsUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }
}

/// Fetches a document, or null when the request failed or was not a 200.
typedef AppReleaseFetcher = Future<String?> Function(Uri uri);

/// Streams [uri] into [destination].
typedef AppFileDownloader = Future<void> Function(Uri uri, File destination);

/// Installs an APK file whose SHA-256 digest has been verified.
///
/// Production wiring passes the platform installer's `installApk` method;
/// keeping it a function lets the checker be unit tested without the Android
/// channel.
typedef AppApkInstaller = Future<void> Function(String apkPath);

/// A download or verification failure. The APK is never handed to the
/// installer when one of these escapes.
class AppReleaseException implements Exception {
  const AppReleaseException(this.message);

  final String message;

  @override
  String toString() => 'AppReleaseException: $message';
}

/// Reads the latest wmr-companion release and downloads its APK with a
/// verified SHA-256 digest.
///
/// [fetch] and [download] are injectable for tests; [cacheFor] keeps repeat
/// screen builds from re-querying GitHub. Network and parse failures degrade
/// to null from [latest], matching the bridge release checker's "no banner
/// rather than an error" behaviour.
class AppReleaseChecker {
  AppReleaseChecker({
    AppReleaseFetcher? fetch,
    AppFileDownloader? download,
    Future<Directory> Function()? tempDirectory,
    DateTime Function()? clock,
    this.cacheFor = const Duration(hours: 1),
  }) : _fetch = fetch ?? _fetchDocument,
       _download = download ?? _downloadToFile,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory,
       _clock = clock ?? DateTime.now;

  final AppReleaseFetcher _fetch;
  final AppFileDownloader _download;
  final Future<Directory> Function() _tempDirectory;
  final DateTime Function() _clock;
  final Duration cacheFor;

  ({DateTime at, AppRelease release})? _cached;

  /// The latest release, or null while unknown, offline or unverifiable.
  Future<AppRelease?> latest() async {
    final cached = _cached;
    if (cached != null && _clock().difference(cached.at) < cacheFor) {
      return cached.release;
    }
    try {
      final body = await _fetch(Uri.parse(appLatestReleaseUrl));
      if (body == null) return null;
      final release = AppRelease.parse(body);
      if (release != null) _cached = (at: _clock(), release: release);
      return release;
    } catch (_) {
      // Offline, DNS failure or a timeout: no banner rather than an error.
      return null;
    }
  }

  /// Downloads [release]'s APK into temporary storage and verifies its
  /// SHA-256 digest against `SHA256SUMS`.
  ///
  /// Returns the verified file. Throws [AppReleaseException] when the download
  /// fails, the checksum file has no entry for the APK, or the digests differ;
  /// in every failure the partial file is deleted before the error escapes.
  Future<File> downloadVerified(AppRelease release) async {
    final root = await _tempDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}wmr-companion-update',
    );
    await directory.create(recursive: true);
    final destination = File(
      '${directory.path}${Platform.pathSeparator}${release.apkName}',
    );
    try {
      await _download(release.apkUrl, destination);
      final expected = await _expectedDigest(release);
      final actual = await _fileDigest(destination);
      if (expected != actual) {
        throw AppReleaseException(
          'SHA-256 mismatch for ${release.apkName}: '
          'expected $expected, got $actual',
        );
      }
      return destination;
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  /// Downloads and verifies [release], then passes the verified file's path to
  /// [install]. [install] is not called when verification fails.
  Future<File> downloadAndInstall(
    AppRelease release,
    AppApkInstaller install,
  ) async {
    final apk = await downloadVerified(release);
    await install(apk.path);
    return apk;
  }

  /// The digest `SHA256SUMS` lists for [release]'s APK.
  Future<String> _expectedDigest(AppRelease release) async {
    final body = await _fetch(release.checksumUrl);
    if (body == null) {
      throw const AppReleaseException('SHA256SUMS could not be downloaded');
    }
    final digest = parseChecksum(body, release.apkName);
    if (digest == null) {
      throw AppReleaseException(
        'SHA256SUMS has no entry for ${release.apkName}',
      );
    }
    return digest;
  }

  /// Finds the digest for [apkName] in a `sha256sum` document.
  ///
  /// Accepts the text and binary (`*`) markers and any run of whitespace, so
  /// both `sha256sum` output and GitHub's recomputed file parse.
  static String? parseChecksum(String document, String apkName) {
    for (final line in const LineSplitter().convert(document)) {
      final match = _checksumLine.firstMatch(line.trim());
      if (match != null && match.group(2) == apkName) {
        return match.group(1)!.toLowerCase();
      }
    }
    return null;
  }

  static final RegExp _checksumLine = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)$');

  static Future<String> _fileDigest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static Future<String?> _fetchDocument(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(uri);
      // GitHub rejects API requests that do not identify a client.
      request.headers.set(HttpHeaders.userAgentHeader, 'wmr-companion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _downloadToFile(Uri uri, File destination) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'wmr-companion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw AppReleaseException(
          'APK download failed with HTTP ${response.statusCode}',
        );
      }
      await response.pipe(destination.openWrite());
    } finally {
      client.close(force: true);
    }
  }
}
