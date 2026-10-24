/// Real-socket loopback check for the Wi-Fi transport.
///
/// Connects to a running `wmr_bridge` daemon (normally started in `--replay`
/// mode, so no Pi and no controllers are involved), subscribes to one stream,
/// and prints the counters the PR body quotes. It then replays the *same* FF12
/// record bytes through the app's fake transport path and asserts every
/// decoded field is identical, so the transport is proven byte-transparent.
///
/// ```sh
/// cd packages/wmr_ws
/// dart run tool/loopback_check.dart --host 127.0.0.1 --port 8799 \
///     --stream batched --duration 6
/// ```
///
/// Exit code 0 means: records arrived on both hands, no sequence gaps, no parse
/// errors, and the fake path reproduced every field.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wmr_core/ble/ble_transport.dart';
import 'package:wmr_core/ble/fake_transport.dart';
import 'package:wmr_core/domain/hand_pipeline.dart';
import 'package:wmr_core/protocol/decoded_batch.dart';
import 'package:wmr_core/protocol/decoded_record.dart';
import 'package:wmr_core/protocol/gatt.dart';
import 'package:wmr_core/protocol/wmr_fragment.dart';
import 'package:wmr_core/services/controller_service.dart';
import 'package:wmr_ws/wmr_ws.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final endpoint = WmrWsEndpoint(
    host: options.host,
    port: options.port,
    path: options.path,
    token: options.token,
  );
  final transport = WmrWsTransport(endpoints: [endpoint]);
  final id = endpoint.resolvedDeviceId;
  final capture = _Capture();
  final reassembler = WmrReassembler();

  try {
    await transport.connect(id);
    final hello = transport.helloFor(id)!;
    stdout.writeln('hello: ${jsonEncode(_helloJson(hello))}');

    final characteristic = switch (options.stream) {
      'raw' => wmrBridgeStreamCharUuid,
      'decoded' => wmrBridgeDecodedCharUuid,
      'batched' => wmrBridgeBatchedCharUuid,
      _ => throw ArgumentError.value(options.stream, 'stream'),
    };

    final sub = transport
        .subscribe(id, wmrBridgeServiceUuid, characteristic)
        .listen(
          (notification) {
            switch (options.stream) {
              case 'raw':
                final result = reassembler.push(notification.value);
                if (result == ReassemblyResult.frameComplete) {
                  capture.rawFrames++;
                }
              case 'decoded':
                final parsed = parseDecodedRecord(notification.value);
                if (parsed.record == null) {
                  capture.parseErrors++;
                  return;
                }
                capture.add(parsed.record!, notification.value);
              case 'batched':
                final parsed = parseDecodedBatch(notification.value);
                final parsedRecords = parsed.records;
                if (parsedRecords == null) {
                  capture.parseErrors++;
                  return;
                }
                capture.batches.add(notification.value);
                for (final item in parsedRecords) {
                  final record = item.record;
                  if (record == null) {
                    capture.parseErrors++;
                    continue;
                  }
                  capture.add(record, null);
                }
            }
          },
          onError: (Object error) {
            stderr.writeln('stream error: $error');
            capture.streamError = error;
          },
        );

    stdout.writeln(
      'subscribed: ${options.stream} for ${options.duration.inMilliseconds} ms',
    );
    await Future<void>.delayed(options.duration);
    await sub.cancel();
    await transport.unsubscribe(id, wmrBridgeServiceUuid, characteristic);

    final status = await transport.status(id);
    final transportStats = transport.statsFor(id);
    capture.rawIncomplete =
        reassembler.framesIncomplete[wmrHandLeft] +
        reassembler.framesIncomplete[wmrHandRight];
    final fake = options.stream == 'raw'
        ? const _FakePathResult(samples: [], batches: 0)
        : await _fakePath(capture);

    final fieldsEqual =
        options.stream != 'raw' && _fieldsEqual(capture.records, fake.samples);
    final summary = <String, Object?>{
      'endpoint': endpoint.uri.toString(),
      'hello': _helloJson(hello),
      'stream': options.stream,
      'durationMs': options.duration.inMilliseconds,
      'counters': capture.toJson(),
      'daemonStatus': {
        'uptimeS': status.uptimeS,
        'dropped': status.dropped,
        'batches': status.batches,
        'hands': [
          for (final hand in status.hands)
            {
              'hand': hand.hand == 0 ? 'LEFT' : 'RIGHT',
              'reports': hand.reports,
              'decoded': hand.decoded,
              'delivered': hand.delivered,
              'errors': hand.errors,
              'dropped': hand.dropped,
              'sequence': hand.sequence,
            },
        ],
      },
      'transportStats': {
        'payloadMessages': transportStats.payloadMessages,
        'textMessages': transportStats.textMessages,
        'droppedByQueue': transportStats.droppedByQueue,
        'unexpectedMessages': transportStats.unexpectedMessages,
      },
      'fakePath': fake.toJson(),
      'checks': {
        'records': capture.records.length,
        'recordsOnBothHands':
            capture.byHand(wmrHandLeft) > 0 && capture.byHand(wmrHandRight) > 0,
        'noSequenceGaps': capture.gaps.values.every((value) => value == 0),
        'noOutOfOrder': capture.outOfOrder.values.every((value) => value == 0),
        'noParseErrors': capture.parseErrors == 0,
        'noStreamError': capture.streamError == null,
        'fakePathFieldsEqual': options.stream == 'raw' ? null : fieldsEqual,
        if (options.stream == 'raw') 'rawFrames': capture.rawFrames > 0,
      },
    };

    stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));

    final checks = summary['checks']! as Map<String, Object?>;
    if (options.stream == 'raw' &&
        capture.rawFrames > 0 &&
        reassembler.errors == 0) {
      stdout.writeln(
        'OK: raw stream delivered ${capture.rawFrames} complete frames '
        '(${capture.rawIncomplete} incomplete, ${reassembler.errors} errors)',
      );
    } else if (checks.values.any((value) => value == false)) {
      stderr.writeln('FAIL: ${_failedChecks(checks).join(', ')}');
      exitCode = 1;
    } else {
      stdout.writeln('OK: transport and fake path agree on every field');
    }
  } finally {
    await transport.dispose();
  }
}

List<String> _failedChecks(Map<String, Object?> checks) => [
  for (final entry in checks.entries)
    if (entry.value == false) entry.key,
];

class _Capture {
  final List<DecodedRecord> records = [];
  final List<Uint8List> batches = [];
  final Map<int, int?> lastSequence = {wmrHandLeft: null, wmrHandRight: null};
  final Map<int, int?> firstSequence = {wmrHandLeft: null, wmrHandRight: null};
  final Map<int, int> gaps = {wmrHandLeft: 0, wmrHandRight: 0};
  final Map<int, int> outOfOrder = {wmrHandLeft: 0, wmrHandRight: 0};
  int parseErrors = 0;
  int rawFrames = 0;
  int rawIncomplete = 0;
  Object? streamError;

  void add(DecodedRecord record, Uint8List? source) {
    records.add(record);
    if (source != null) {
      // A decoded notification is exactly one batch of one record; feed that
      // shape to the fake path so both runs see identical bytes.
      batches.add(encodeDecodedBatch([source]));
    }
    firstSequence.putIfAbsent(record.hand, () => record.sequence);
    if (firstSequence[record.hand] == null) {
      firstSequence[record.hand] = record.sequence;
    }
    final previous = lastSequence[record.hand];
    if (previous != null) {
      final delta = sequenceDelta(previous, record.sequence);
      if (delta > 1) gaps[record.hand] = gaps[record.hand]! + delta - 1;
      if (delta <= 0) outOfOrder[record.hand] = outOfOrder[record.hand]! + 1;
    }
    lastSequence[record.hand] = record.sequence;
  }

  int byHand(int hand) => records.where((record) => record.hand == hand).length;

  Map<String, Object?> toJson() => {
    'records': records.length,
    'batches': batches.length,
    'byHand': {'LEFT': byHand(wmrHandLeft), 'RIGHT': byHand(wmrHandRight)},
    'firstSequence': {
      'LEFT': firstSequence[wmrHandLeft],
      'RIGHT': firstSequence[wmrHandRight],
    },
    'lastSequence': {
      'LEFT': lastSequence[wmrHandLeft],
      'RIGHT': lastSequence[wmrHandRight],
    },
    'sequenceGaps': {'LEFT': gaps[wmrHandLeft], 'RIGHT': gaps[wmrHandRight]},
    'outOfOrder': {
      'LEFT': outOfOrder[wmrHandLeft],
      'RIGHT': outOfOrder[wmrHandRight],
    },
    'rawFrames': rawFrames,
    'rawIncomplete': rawIncomplete,
    'parseErrors': parseErrors,
    'streamError': streamError?.toString(),
  };
}

Map<String, Object?> _helloJson(WmrWsHello hello) => {
  'protocol': hello.protocol,
  'transport': hello.transport,
  'device': hello.device,
  'version': hello.version,
  'hostname': hello.hostname,
  'authRequired': hello.authRequired,
  'streams': hello.streams.toList(),
  'recordSize': hello.recordSize,
  'batchMax': hello.batchMax,
  'fragmentCapacity': hello.fragmentCapacity,
};

class _FakePathResult {
  const _FakePathResult({required this.samples, required this.batches});

  final List<DecodedSample> samples;
  final int batches;

  Map<String, Object?> toJson() => {
    'records': samples.length,
    'batches': batches,
    'byHand': {
      'LEFT': samples.where((s) => s.record.hand == wmrHandLeft).length,
      'RIGHT': samples.where((s) => s.record.hand == wmrHandRight).length,
    },
  };
}

/// Runs the *same* FF12 bytes through `FakeTransport` + `ControllerService`,
/// which is the path `FakeWmrBridge` drives. It is not a decoder: it proves
/// that the app pipeline sees identical records on both transports.
Future<_FakePathResult> _fakePath(_Capture capture) async {
  if (capture.batches.isEmpty) {
    return const _FakePathResult(samples: [], batches: 0);
  }
  const fakeId = 'loopback-fake';
  final fake = FakeTransport(
    devices: const [
      FakeDevice(
        id: fakeId,
        services: [
          BleServiceInfo(
            uuid: wmrBridgeServiceUuid,
            characteristicUuids: [
              wmrBridgeBatchedCharUuid,
              wmrBridgeDecodedCharUuid,
              wmrBridgeStreamCharUuid,
            ],
          ),
        ],
      ),
    ],
  );
  final service = ControllerService(fake, fakeId, mode: StreamMode.batched);
  final samples = <DecodedSample>[];
  final sub = service.decodedSamples.listen(samples.add);
  try {
    await service.start();
    for (final batch in capture.batches) {
      fake.emit(fakeId, wmrBridgeBatchedCharUuid, batch);
    }
    // No timer is involved; flush the broadcast stream.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  } finally {
    await sub.cancel();
    await service.dispose();
    await fake.dispose();
  }
  return _FakePathResult(samples: samples, batches: capture.batches.length);
}

bool _fieldsEqual(List<DecodedRecord> fromWire, List<DecodedSample> fromFake) {
  if (fromWire.length != fromFake.length) return false;
  for (var i = 0; i < fromWire.length; i++) {
    final a = fromWire[i];
    final b = fromFake[i].record;
    if (a.hand != b.hand ||
        a.flags != b.flags ||
        a.buttons != b.buttons ||
        a.sequence != b.sequence ||
        a.rxTimeUs != b.rxTimeUs ||
        a.deviceTicks != b.deviceTicks ||
        a.temperatureRaw != b.temperatureRaw ||
        a.trigger != b.trigger ||
        a.battery != b.battery ||
        !_listEqual(a.gyro, b.gyro) ||
        !_listEqual(a.accel, b.accel) ||
        !_listEqual(a.stick, b.stick) ||
        !_listEqual(a.trackpad, b.trackpad)) {
      stderr.writeln('field mismatch at record $i: $a vs $b');
      return false;
    }
  }
  return true;
}

bool _listEqual(List<num> a, List<num> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Options {
  const _Options({
    required this.host,
    required this.port,
    required this.path,
    required this.stream,
    required this.duration,
    this.token,
    this.help = false,
  });

  final String host;
  final int port;
  final String path;
  final String stream;
  final Duration duration;
  final String? token;
  final bool help;

  static _Options parse(List<String> arguments) {
    var host = '127.0.0.1';
    var port = 8765;
    var path = '/wmr';
    var stream = 'batched';
    var duration = const Duration(seconds: 5);
    String? token;
    var help = false;
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      String next() {
        if (i + 1 >= arguments.length) {
          throw ArgumentError('$argument needs a value');
        }
        return arguments[++i];
      }

      switch (argument) {
        case '--host':
          host = next();
        case '--port':
          port = int.parse(next());
        case '--path':
          path = next();
        case '--stream':
          stream = next();
        case '--duration':
          duration = Duration(
            milliseconds: (double.parse(next()) * 1000).round(),
          );
        case '--token':
          token = next();
        case '--help' || '-h':
          help = true;
        default:
          throw ArgumentError('unknown argument $argument');
      }
    }
    return _Options(
      host: host,
      port: port,
      path: path,
      stream: stream,
      duration: duration,
      token: token,
      help: help,
    );
  }
}

const _usage = '''
Usage: dart run tool/loopback_check.dart [options]

  --host HOST       bridge host (default 127.0.0.1)
  --port PORT       WebSocket port (default 8765)
  --path PATH       WebSocket path (default /wmr)
  --stream NAME     raw | decoded | batched (default batched)
  --duration SEC    capture time in seconds (default 5)
  --token TOKEN     shared token, when the daemon requires one
''';
