import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion/services/config_key_store.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.assets);
  final Map<String, Uint8List> assets;

  @override
  Future<ByteData> load(String key) async {
    final a = assets[key];
    if (a == null) throw FlutterError('Unable to load asset: $key');
    return ByteData.sublistView(a);
  }
}

void main() {
  test('a missing key is reported with the fix, not thrown', () async {
    final r = await loadConfigKey(bundle: _Bundle({}));
    expect(r.status, ConfigKeyStatus.missing);
    expect(r.key, isNull);
    expect(r.message, contains('tool/fetch_wmr_config_key.dart'));
  });

  test('a key of the wrong size is reported', () async {
    final r = await loadConfigKey(
      bundle: _Bundle({wmrConfigKeyAsset: Uint8List(1000)}),
    );
    expect(r.status, ConfigKeyStatus.wrongSize);
    expect(r.message, contains('1000'));
  });

  test('a 1024-byte key loads', () async {
    final k = Uint8List.fromList([for (var i = 0; i < 1024; i++) i & 0xff]);
    final r = await loadConfigKey(bundle: _Bundle({wmrConfigKeyAsset: k}));
    expect(r.status, ConfigKeyStatus.ok);
    expect(r.key, k);
  });
}
