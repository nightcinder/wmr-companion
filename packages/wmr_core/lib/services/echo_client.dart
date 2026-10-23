import 'dart:async';

import '../ble/ble_transport.dart';
import '../protocol/echo.dart';
import '../protocol/gatt.dart';

/// One answered ping. Phone times are on the transport's monotonic clock, the
/// ESP32 times (inside [answer]) on the ESP32 clock: only differences within
/// one clock are meaningful.
class EchoSample {
  const EchoSample({
    required this.t1Us,
    required this.t1DoneUs,
    required this.t4Us,
    required this.answer,
  });

  /// Phone time just before the write was handed to the transport. The
  /// transport serializes GATT operations, so this includes any wait behind
  /// them and the plugin's own delay.
  final int t1Us;

  /// Phone time when the write call returned. [t1Us] to here is what the
  /// write itself cost the app.
  final int t1DoneUs;

  /// Phone arrival time of the answer.
  final int t4Us;
  final EchoAnswer answer;

  int get pingId => answer.pingId;

  /// What the app sees end to end: write call to notification.
  int get endToEndUs => t4Us - t1Us;

  /// `(t4 - t1) - (t3 - t2)` from the spec: the round trip without the time
  /// the answer waited on the ESP32. Includes the app, plugin, both
  /// Bluetooth stacks and the air.
  int get rttUs => endToEndUs - answer.turnaroundUs;

  /// Estimate of `esp32 - phone` clock offset, error up to `rtt / 2`
  /// (the spec's `((t2 - t1) + (t3 - t4)) / 2`).
  int get offsetUs =>
      ((answer.rxTimeUs - t1Us) +
          (answer.rxTimeUs + answer.turnaroundUs - t4Us)) ~/
      2;
}

enum EchoFailure {
  /// No answer within the timeout.
  timeout,

  /// The write failed ([EchoClient.lastError]).
  writeFailed,

  /// A ping was still waiting, so none was sent.
  busy,

  /// The client was disposed, or never started.
  cancelled,
}

/// Outcome of one [EchoClient.ping]: exactly one of [sample] and [failure].
class EchoResult {
  const EchoResult.answered(EchoSample this.sample) : failure = null;
  const EchoResult.failed(EchoFailure this.failure) : sample = null;

  final EchoSample? sample;
  final EchoFailure? failure;
}

enum EchoSupport {
  /// Not looked yet.
  unknown,
  supported,

  /// The connected bridge does not have FF15 (firmware older than WMR_Bridge
  /// #13). Nothing was subscribed or written.
  unsupported,
}

/// Round trip over the bridge's FF15 echo characteristic.
///
/// One ping at a time, as the firmware allows. Independent of the stream the
/// service listens to: FF15 is outside the FF11/FF12/FF14 exclusion, so this
/// never touches the service's subscription. Firmware not run on hardware.
class EchoClient {
  EchoClient(
    this.transport,
    this.deviceId, {
    this.timeout = const Duration(seconds: 1),
  });

  final BleTransport transport;
  final String deviceId;

  /// How long to wait for an answer (the firmware suggests 1 s).
  final Duration timeout;

  EchoSupport _support = EchoSupport.unknown;
  StreamSubscription<BleNotification>? _sub;
  int _nextId = 1;
  int? _pendingId;
  int _pendingT1 = 0;
  int _pendingT1Done = 0;
  Completer<EchoResult>? _pending;

  int sent = 0;
  int answered = 0;
  int timeouts = 0;

  /// Answers that matched no waiting ping: late ones after a timeout, or
  /// duplicates.
  int stale = 0;

  /// Answers dropped for length or version.
  int badAnswers = 0;

  /// Pings not sent because one was still waiting.
  int skipped = 0;
  Object? lastError;

  EchoSupport get support => _support;
  bool get busy => _pending != null;

  /// Looks for FF15 and enables its notifications. False when the bridge has
  /// no FF15 or the setup failed ([lastError]). Safe to call again.
  Future<bool> start() async {
    if (_sub != null) return true;
    try {
      final services = await transport.discoverServices(deviceId);
      final found = services.any(
        (s) =>
            s.uuid.toLowerCase() == wmrBridgeServiceUuid &&
            s.characteristicUuids.any(
              (c) => c.toLowerCase() == wmrBridgeEchoCharUuid,
            ),
      );
      if (!found) {
        _support = EchoSupport.unsupported;
        return false;
      }
      _support = EchoSupport.supported;
      _sub = transport
          .subscribe(deviceId, wmrBridgeServiceUuid, wmrBridgeEchoCharUuid)
          .listen(_onAnswer, onError: (Object e) => lastError = e);
      return true;
    } catch (e) {
      lastError = e;
      return false;
    }
  }

  /// Sends one ping and waits for its answer. A ping that is still waiting
  /// makes this return [EchoFailure.busy] (and grow [skipped]). Call [start]
  /// first.
  Future<EchoResult> ping() async {
    if (_sub == null) return const EchoResult.failed(EchoFailure.cancelled);
    if (_pending != null) {
      skipped++;
      return const EchoResult.failed(EchoFailure.busy);
    }
    final id = _nextId;
    _nextId = (_nextId + 1) & 0xffff;
    final completer = _pending = Completer<EchoResult>();
    _pendingId = id;
    _pendingT1Done = 0;
    _pendingT1 = transport.clock.nowUs;
    sent++;
    try {
      await transport.write(
        deviceId,
        wmrBridgeServiceUuid,
        wmrBridgeEchoCharUuid,
        encodeEchoRequest(id),
        withoutResponse: true,
      );
      if (!completer.isCompleted) _pendingT1Done = transport.clock.nowUs;
    } catch (e) {
      lastError = e;
      final r = const EchoResult.failed(EchoFailure.writeFailed);
      _finish(completer, r);
      return r;
    }
    // The answer may have beaten this continuation; then it is done already.
    if (completer.isCompleted) return completer.future;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        timeouts++;
        _finish(completer, const EchoResult.failed(EchoFailure.timeout));
      }
    });
    final result = await completer.future;
    timer.cancel();
    return result;
  }

  void _finish(Completer<EchoResult> c, EchoResult result) {
    if (identical(_pending, c)) {
      _pending = null;
      _pendingId = null;
    }
    if (!c.isCompleted) c.complete(result);
  }

  void _onAnswer(BleNotification n) {
    final parsed = parseEchoAnswer(n.value);
    final a = parsed.answer;
    if (a == null) {
      badAnswers++;
      return;
    }
    final c = _pending;
    if (c == null || a.pingId != _pendingId) {
      stale++;
      return;
    }
    answered++;
    _finish(
      c,
      EchoResult.answered(
        EchoSample(
          t1Us: _pendingT1,
          t1DoneUs: _pendingT1Done == 0 ? _pendingT1 : _pendingT1Done,
          t4Us: n.receivedAtUs,
          answer: a,
        ),
      ),
    );
  }

  Future<void> dispose() async {
    final c = _pending;
    if (c != null) _finish(c, const EchoResult.failed(EchoFailure.cancelled));
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    if (_support == EchoSupport.supported) {
      try {
        await transport.unsubscribe(
          deviceId,
          wmrBridgeServiceUuid,
          wmrBridgeEchoCharUuid,
        );
      } catch (_) {
        // The link may be gone already; the bridge clears the CCC itself.
      }
    }
  }
}
