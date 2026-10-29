/// Firmware identity shared by the bench run and the bundle manifest.
///
/// FF16 reports the firmware `PROJECT_VER` (for example `0.2.4-3-gdeadbee`),
/// not a commit on its own. Only the `-g<sha>` shape a git-describe version
/// carries is a commit, so everything that labels a value a SHA goes through
/// [gitShaFromFirmware] first.
library;

/// The short SHA in an FF16 git description, or null when FF16 has none.
///
/// Only the `-g<sha>` shape a git-describe version carries counts. A bare hex
/// token is not a SHA: versions and build stamps can look identical.
String? gitShaFromFirmware(String? version) {
  if (version == null) return null;
  final match = RegExp(r'(?:^|-)g([0-9a-f]{7,40})(?:[-\s+]|$)')
      .firstMatch(version.trim());
  return match?.group(1);
}

/// The SHA recorded for a run: one value when every bridge that exposes a git
/// description agrees, a per-bridge list when they differ, else `unknown`.
String firmwareShaFromVersions(Map<String, String?> versions) {
  final found = <String, String>{};
  for (final entry in versions.entries) {
    final sha = gitShaFromFirmware(entry.value);
    if (sha != null) found[entry.key] = sha;
  }
  if (found.isEmpty) return 'unknown';
  if (found.values.toSet().length == 1) return found.values.first;
  return found.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
}
