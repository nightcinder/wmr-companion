import 'package:flutter/services.dart';

import 'package:wmr_core/protocol/config_decode.dart';

/// Where `tool/fetch_wmr_config_key.dart` writes the key. Gitignored: the
/// table is Monado's (BSL-1.0) and is not committed to this repository.
const String wmrConfigKeyAsset = 'assets/monado/wmr_config_key.bin';

enum ConfigKeyStatus {
  ok,

  /// The asset is not in the build: run `tool/fetch_wmr_config_key.dart` from
  /// `apps/wmr_companion_app` and rebuild. Reading the config block still
  /// works; decoding it does not.
  missing,

  /// The asset exists but is not 1024 bytes.
  wrongSize,
}

class ConfigKeyResult {
  const ConfigKeyResult.ok(Uint8List this.key)
    : status = ConfigKeyStatus.ok,
      size = wmrConfigKeySize;
  const ConfigKeyResult.problem(this.status, {this.size}) : key = null;

  final ConfigKeyStatus status;
  final Uint8List? key;

  /// The size found, for [ConfigKeyStatus.wrongSize].
  final int? size;

  String get message => switch (status) {
    ConfigKeyStatus.ok => 'Monado config key loaded',
    ConfigKeyStatus.missing =>
      'Monado config key not in this build. Run '
          '`dart run ../../tool/fetch_wmr_config_key.dart` from '
          'apps/wmr_companion_app, then rebuild.',
    ConfigKeyStatus.wrongSize =>
      'Monado config key has $size bytes, expected $wmrConfigKeySize.',
  };
}

/// Loads the key from the app's assets. Never throws for a missing or
/// malformed key; the caller shows [ConfigKeyResult.message].
Future<ConfigKeyResult> loadConfigKey({AssetBundle? bundle}) async {
  final b = bundle ?? rootBundle;
  final ByteData data;
  try {
    data = await b.load(wmrConfigKeyAsset);
  } catch (_) {
    return const ConfigKeyResult.problem(ConfigKeyStatus.missing);
  }
  if (data.lengthInBytes != wmrConfigKeySize) {
    return ConfigKeyResult.problem(
      ConfigKeyStatus.wrongSize,
      size: data.lengthInBytes,
    );
  }
  return ConfigKeyResult.ok(
    Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    ),
  );
}
