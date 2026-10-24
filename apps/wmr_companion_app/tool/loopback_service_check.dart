/// Real-socket loopback run of the **app service layer** against the Pi
/// daemon in `--replay` mode.
///
/// `ControllerService` is the layer the connect screen drives: it owns the
/// transport, reassembles FF11, parses FF12/FF14 and keeps the per-bridge
/// counters the debug and latency screens read. This check starts that
/// service over [WmrWsTransport] (no BLE, no Pi, no controllers), records for
/// a few seconds and prints the counters the pull request quotes.
///
/// ```sh
/// cd apps/wmr_companion_app
/// dart run tool/loopback_service_check.dart \
///     --host 127.0.0.1 --port 8799 --stream batched --duration 6
/// ```
///
/// Exit code 0 means records arrived on both hands, neither hand lost a
/// sequence number, and the service reported no parse or reassembly errors.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  final service = ControllerService(transport, id, mode: options.mode);
  StreamStats? raw;
  DecodedStats? decoded;

  try {
    await service.start();
    final hello = transport.helloFor(id);
    stdout.writeln(
      'hello: ${hello == null ? 'n/a' : jsonEncode(_helloJson(hello))}',
    );
    stdout.writeln(
      'service started: ${options.mode.name} for '
      '${options.duration.inMilliseconds} ms',
    );
    await Future<void>.delayed(options.duration);
    raw = service.stats;
    decoded = service.decodedStats;

    final status = await transport.status(id);
    final transportStats = transport.statsFor(id);
    final summary = <String, Object?>{
      'endpoint': endpoint.uri.toString(),
      'bridgeId': id,
      'stream': options.mode.name,
      'durationMs': options.duration.inMilliseconds,
      'hello': hello == null ? null : _helloJson(hello),
      'service': {
        'mode': service.mode.name,
        'fault': service.fault?.message,
        'raw': _rawJson(raw),
        'decoded': _decodedJson(decoded),
      },
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
      'checks': _checks(options.mode, raw, decoded),
    };
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));

    final failed = [
      for (final entry in (summary['checks']! as Map<String, Object?>).entries)
        if (entry.value == false) entry.key,
    ];
    if (failed.isEmpty) {
      stdout.writeln('OK: app service layer delivered both hands cleanly');
    } else {
      stderr.writeln('FAIL: ${failed.join(', ')}');
      exitCode = 1;
    }
  } finally {
    await service.dispose();
    await transport.dispose();
  }
}

Map<String, Object?> _checks(
  StreamMode mode,
  StreamStats raw,
  DecodedStats decoded,
) {
  if (mode.carriesRecords) {
    final left = decoded.hands[wmrHandLeft];
    final right = decoded.hands[wmrHandRight];
    return {
      'recordsBothHands': left.records > 0 && right.records > 0,
      'noSequenceGaps': left.sequenceGaps == 0 && right.sequenceGaps == 0,
      'noOutOfOrder': left.outOfOrder == 0 && right.outOfOrder == 0,
      'noParseErrors': decoded.parseErrors == 0,
    };
  }
  final left = raw.hands[wmrHandLeft];
  final right = raw.hands[wmrHandRight];
  return {
    'framesBothHands': left.frames > 0 && right.frames > 0,
    'noIncompleteFrames': left.incomplete == 0 && right.incomplete == 0,
    'noReassemblyErrors': raw.errors == 0,
    'noSequenceGaps': left.gaps == 0 && right.gaps == 0,
    'noOutOfOrder': left.outOfOrder == 0 && right.outOfOrder == 0,
  };
}

Map<String, Object?> _rawJson(StreamStats stats) => {
  'hands': [
    for (final hand in stats.hands)
      {
        'frames': hand.frames,
        'incomplete': hand.incomplete,
        'sequence': hand.lastSequence,
        'gaps': hand.gaps,
        'outOfOrder': hand.outOfOrder,
      },
  ],
  'reassemblyErrors': stats.errors,
};

Map<String, Object?> _decodedJson(DecodedStats stats) => {
  'hands': [
    for (final hand in stats.hands)
      {
        'records': hand.records,
        'rateHz': hand.rateHz,
        'sequence': hand.lastSequence,
        'sequenceGaps': hand.sequenceGaps,
        'outOfOrder': hand.outOfOrder,
        'missingFromTicks': hand.missingFromTicks,
        'periodTicks': hand.periodTicks,
      },
  ],
  'parseErrors': stats.parseErrors,
  'batches': stats.batches,
  'batchRecords': stats.batchRecords,
  'batchErrors': stats.batchErrors,
};

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

const _usage = '''
Runs ControllerService (the app service layer) against a wmr_bridge daemon.

  --host <host>       default 127.0.0.1
  --port <port>       default 8799
  --path <path>       default /wmr
  --token <token>     optional shared token
  --stream <mode>     raw | decoded | batched (default batched)
  --duration <ms>     capture length (default 6000)
  --help
''';

class _Options {
  const _Options({
    required this.host,
    required this.port,
    required this.path,
    required this.token,
    required this.mode,
    required this.duration,
    required this.help,
  });

  final String host;
  final int port;
  final String path;
  final String? token;
  final StreamMode mode;
  final Duration duration;
  final bool help;

  static _Options parse(List<String> args) {
    var host = '127.0.0.1';
    var port = 8799;
    var path = wmrWsDefaultPath;
    String? token;
    var mode = StreamMode.batched;
    var duration = const Duration(seconds: 6);
    var help = false;

    for (var i = 0; i < args.length; i++) {
      String next() {
        if (i + 1 >= args.length) {
          throw ArgumentError('missing value for ${args[i]}');
        }
        return args[++i];
      }

      switch (args[i]) {
        case '--host':
          host = next();
        case '--port':
          port = int.parse(next());
        case '--path':
          path = next();
        case '--token':
          token = next();
        case '--stream':
          mode = switch (next()) {
            'raw' => StreamMode.raw,
            'decoded' => StreamMode.decoded,
            'batched' => StreamMode.batched,
            final value => throw ArgumentError('unknown stream: $value'),
          };
        case '--duration':
          duration = Duration(milliseconds: int.parse(next()));
        case '--help' || '-h':
          help = true;
        default:
          throw ArgumentError('unknown option: ${args[i]}');
      }
    }
    return _Options(
      host: host,
      port: port,
      path: path,
      token: token,
      mode: mode,
      duration: duration,
      help: help,
    );
  }
}
