import 'dart:typed_data';

import '../protocol/decoded_batch.dart' show wmrBatchMaxCount, wmrBatchVersion;
import '../protocol/decoded_record.dart';
import '../protocol/wmr_fragment.dart';
import 'imu_log_format.dart';

/// Receives finished byte chunks. Returns false when it cannot take the
/// chunk now (for example its queue is full); the recorder then drops it and
/// counts it in [ImuLogRecorder.chunksRefused].
abstract class ImuLogSink {
  bool add(Uint8List chunk);
  Future<void> close();
}

/// Writes the raw FF12/FF14 stream in the [imuLogFormat] layout.
///
/// Records are staged in memory and handed to the sink in chunks of at
/// least [handoffBytes], or when the oldest staged record is [handoffUs]
/// older than the newest one. Time is taken from the `receivedAtUs` values
/// passed in, so the recorder never starts a timer and tests stay
/// deterministic.
class ImuLogRecorder {
  ImuLogRecorder({
    required this.sink,
    required int stream,
    required int mtu,
    required int startUs,
    this.handoffBytes = 16 * 1024,
    this.handoffUs = 50000,
    this.statsIntervalUs = 5000000,
  }) : assert(stream == 12 || stream == 14) {
    _staging.add(
      encodeImuLogHeader(stream: stream, mtu: mtu, startUs: startUs),
    );
    _stagedBytes += imuLogHeaderSize;
    _lastStatsUs = startUs;
  }

  final ImuLogSink sink;
  final int handoffBytes;
  final int handoffUs;
  final int statsIntervalUs;

  final List<Uint8List> _staging = [];
  int _stagedBytes = 0;
  int? _stagedSinceUs;
  int _lastStatsUs = 0;
  bool _closed = false;

  final Map<String, int> _bridgeIndex = {};
  final Map<int, int> _lastSeq = {};

  /// Records staged so far, all types. Used as STATS records_written.
  int recordsWritten = 0;

  /// Chunks the sink refused. Their records are missing from the file.
  int chunksRefused = 0;

  int _gapsLeft = 0;
  int _gapsRight = 0;
  int _outOfOrderLeft = 0;
  int _outOfOrderRight = 0;

  bool get isClosed => _closed;

  /// Tap for ControllerService.onStreamValue. [value] is a 56-byte FF12
  /// notification or an FF14 batch; anything else is ignored.
  void onStreamValue(Uint8List value, int receivedAtUs, String sourceDeviceId) {
    if (_closed) return;
    final bridge = _bridgeFor(sourceDeviceId);
    if (value.length == wmrDecodedSize) {
      _writeRecord(value, 0, 0, bridge, receivedAtUs);
      return;
    }
    if (value.length < 2 || value[0] != wmrBatchVersion) return;
    final count = value[1];
    if (count < 1 ||
        count > wmrBatchMaxCount ||
        value.length != 2 + count * wmrDecodedSize) {
      return;
    }
    for (var i = 0; i < count; i++) {
      final start = 2 + i * wmrDecodedSize;
      _writeRecord(
        Uint8List.sublistView(value, start, start + wmrDecodedSize),
        i,
        count,
        bridge,
        receivedAtUs,
      );
    }
  }

  void recordEvent({
    required int code,
    required String sourceDeviceId,
    required int hand,
    required int receivedAtUs,
  }) {
    if (_closed) return;
    _stage(
      encodeImuEvent(
        code: code,
        bridge: _bridgeFor(sourceDeviceId),
        hand: hand,
        receivedAtUs: receivedAtUs,
      ),
      receivedAtUs,
    );
  }

  /// Hands any staged bytes to the sink now.
  void flush() {
    if (_staging.isEmpty || _closed) return;
    _handOff();
  }

  /// Writes a final STATS record, flushes and closes the sink.
  Future<void> close({required int receivedAtUs}) async {
    if (_closed) return;
    _writeStats(receivedAtUs);
    _handOff();
    _closed = true;
    await sink.close();
  }

  int _bridgeFor(String id) {
    return _bridgeIndex.putIfAbsent(id, () {
      final next = _bridgeIndex.length;
      return next >= imuLogBridgeAll ? imuLogBridgeAll - 1 : next;
    });
  }

  void _writeRecord(
    Uint8List record,
    int position,
    int count,
    int bridge,
    int receivedAtUs,
  ) {
    final parsed = parseDecodedRecord(record);
    if (parsed.record == null) return;
    final decoded = parsed.record!;
    final hand = decoded.hand;
    final key = bridge * 2 + hand;
    final last = _lastSeq[key];
    if (last != null) {
      final delta = sequenceDelta(last, decoded.sequence);
      if (delta > 1) {
        if (hand == wmrHandLeft) {
          _gapsLeft += delta - 1;
        } else {
          _gapsRight += delta - 1;
        }
      } else if (delta <= 0) {
        if (hand == wmrHandLeft) {
          _outOfOrderLeft++;
        } else {
          _outOfOrderRight++;
        }
      }
    }
    _lastSeq[key] = decoded.sequence;
    _stage(
      encodeImuSample(
        bridge: bridge,
        position: position,
        count: count,
        receivedAtUs: receivedAtUs,
        record: Uint8List.fromList(record),
      ),
      receivedAtUs,
    );
    if (receivedAtUs - _lastStatsUs >= statsIntervalUs) {
      _writeStats(receivedAtUs);
    }
  }

  void _writeStats(int receivedAtUs) {
    _lastStatsUs = receivedAtUs;
    // The counter covers every record staged before this one.
    _stage(
      encodeImuStats(
        bridge: imuLogBridgeAll,
        receivedAtUs: receivedAtUs,
        recordsWritten: recordsWritten,
        gapsLeft: _gapsLeft,
        gapsRight: _gapsRight,
        outOfOrderLeft: _outOfOrderLeft,
        outOfOrderRight: _outOfOrderRight,
      ),
      receivedAtUs,
    );
  }

  void _stage(Uint8List bytes, int receivedAtUs) {
    _staging.add(bytes);
    _stagedBytes += bytes.length;
    recordsWritten++;
    _stagedSinceUs ??= receivedAtUs;
    final since = _stagedSinceUs!;
    if (_stagedBytes >= handoffBytes || receivedAtUs - since >= handoffUs) {
      _handOff();
    }
  }

  void _handOff() {
    final out = Uint8List(_stagedBytes);
    var offset = 0;
    for (final part in _staging) {
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    _staging.clear();
    _stagedBytes = 0;
    _stagedSinceUs = null;
    if (!sink.add(out)) chunksRefused++;
  }
}
