import 'package:flutter/services.dart';

/// Installs a downloaded APK through Android's `PackageInstaller`.
///
/// The host activity owns the platform side (`MainActivity.kt`); any other
/// platform has no handler, so [canRequestPackageInstalls] reports `false` and
/// [openUnknownSourcesSettings] does nothing.
class AppInstaller {
  AppInstaller({MethodChannel? methods})
    : _methods = methods ?? const MethodChannel(channelName);

  static const channelName = 'com.onyxlens.wmr_companion/app_updater';

  final MethodChannel _methods;

  /// Whether Android will let this app start an APK install without sending
  /// the user to Settings. Pre-Android 8 has no per-app toggle, so it is true.
  Future<bool> canRequestPackageInstalls() async {
    try {
      return await _methods.invokeMethod<bool>('canRequestPackageInstalls') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system screen where the user allows installs from this app.
  Future<void> openUnknownSourcesSettings() async {
    try {
      await _methods.invokeMethod<void>('openUnknownSourcesSettings');
    } on MissingPluginException {
      // No installer on this platform; nothing to open.
    }
  }

  /// Asks `PackageInstaller` to install the APK at [path] over this app.
  ///
  /// Returns when the system reports the install succeeded. Throws a
  /// [PlatformException] when the user cancels, the file is missing, or the
  /// install fails.
  Future<void> installApk(String path) async {
    if (path.trim().isEmpty) {
      throw ArgumentError.value(path, 'path', 'must not be empty');
    }
    await _methods.invokeMethod<void>('installApk', {'path': path});
  }
}
