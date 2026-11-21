import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wmr_companion_app/services/bench_receipt_log.dart';

const _channel = MethodChannel(BenchReceiptLog.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  });

  const timeline = <String, Object?>{
    'first_tcp_record_us': 4200000,
    'first_tcp_record_session': 'AA:BB',
    'first_tcp_record_wall_us': 1700000000000000,
    'episodes': <Object?>[],
  };

  test('an injected receipt logs exactly one matching record', () async {
    final log = BenchReceiptLog(enabled: true);
    final first = await log.report(timeline);
    await log.report(timeline);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'log');
    expect(calls.single.arguments, {
      'tag': 'WmrBenchReceipt',
      'message': first.single,
    });
    expect(
      first.single,
      'session=AA:BB first_tcp_record_us=4200000 '
      'first_tcp_record_wall_us=1700000000000000',
    );
  });

  test('an archived episode is not logged again after the top level', () async {
    final log = BenchReceiptLog(enabled: true);
    await log.report(timeline);
    await log.report({
      'episodes': [timeline],
      'first_tcp_record_us': null,
      'first_tcp_record_session': null,
    });
    expect(calls, hasLength(1));
  });

  test('a disabled (non-debug) logger emits nothing', () async {
    final log = BenchReceiptLog(enabled: false);
    expect(await log.report(timeline), isEmpty);
    expect(calls, isEmpty);
  });

  test('a timeline without a receipt emits nothing', () async {
    final log = BenchReceiptLog(enabled: true);
    await log.report({'first_tcp_record_us': null});
    await log.report(null);
    expect(calls, isEmpty);
  });
}
