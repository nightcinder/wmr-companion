# Per-hand sensor timeline

Status: **specified, not implemented.** There is no `SensorTimeline` in the
code. Today the fusion step uses the tick `dt` (correct) but every consumer
that needs an absolute sample time uses the phone's arrival time of the
notification, and the DroidDeck packet falls back to the send time. This
document specifies the replacement. None of the numbers below has been
measured; the acceptance section says how they will be.

## Problem

A decoded record carries three clocks:

| Clock | Field | Properties |
| --- | --- | --- |
| Controller | `device_ticks` | 100 ns per tick, 32 bits (wraps every 429.5 s), one counter per controller, unrelated origins. The only clock that is taken at the sensor. Its rate against the phone is not known precisely (see "Drift") |
| Bridge | `rx_time_us` | When the bridge received the report. ESP32: `esp_timer_get_time()` in the HID callback, jitter of the Classic link. Pi: a user-space stamp when the daemon reads hidraw, so reports read in one burst share a stamp |
| Phone | `receivedAtUs` | The transport's monotonic stamp of the notification or WebSocket message. Every record of one FF14 batch has the same value; it includes the batch hold, the BLE connection-event wait or the Wi-Fi delay, and scheduling on the phone |

The arrival time is late by a variable amount (user-reported round trips have
a median near 40 ms and a tail above 100 ms on BLE), and equal for up to nine
records of a batch. Used as the sample time it makes a batch look like nine
simultaneous samples. The aligner the app has for tracking-source
timestamps, `SourceClockAligner`
(`packages/wmr_tracking/lib/src/clock.dart`), is not a model to copy: it
follows arrival jitter with a low-pass filter and keeps its old offset
whenever the change is larger than 50 ms, so it has no way back after a real
step in the forward direction.

Goal: for every record, a `host_ns` on the phone's monotonic clock that is
smooth, monotonic per hand, and as close as the data allows to the moment the
sample was taken, without ever replacing the tick `dt` in the filter.

## Model

Per (bridge, hand) and per epoch:

```text
ticks64   = device_ticks unwrapped to 64 bits within the epoch
host_ns   = a + b * ticks64 * 100
```

`a` (nanoseconds) and `b` (dimensionless, near 1) are estimated from arrival
times. `b` is the rate of the controller clock against the phone clock; `a`
places the epoch on the phone clock.

`dt` for integration stays `(ticks - previous) mod 2^32 * 100 ns` from
`TickTimer`. `host_ns` is for everything that relates a sample to another
clock: the DroidDeck `sampleTimeNs`, prediction to display time, alignment
with a headset pose, and the latency figures.

## Unwrapping

Per (bridge, hand): `ticks64 = previous_ticks64 + ((ticks - previous_ticks)
mod 2^32)`; the first sample of an epoch starts at its 32-bit value. This is
valid while two consecutive samples of the hand are less than 429.5 s apart
on the controller clock. A hand served by two bridges has two independent
timelines; ticks are never compared across bridges or across hands.

## Estimating `a` and `b`

Each record gives an observation `x = ticks64 * 100` (ns) and
`y = receivedAtUs * 1000` (ns). `y - (a + b x)` is the delivery delay of that
record plus the estimation error. Delay is never negative, and the smallest
delays in a window are the ones closest to the true offset, so the estimator
uses only those.

1. **Min-delay filter.** Time is cut into windows of 1 s of controller time
   (`x`). In each window the record with the smallest `y - b x` (with the
   current `b`) is kept as the window's anchor `(x_i, y_i)`; the others are
   discarded for estimation. In an FF14 batch that is the newest record of
   the batch, without a special case. A window with fewer than 20 records is
   not used.
2. **Warm-up.** Until 5 anchors exist, `b = 1` and
   `a = min_i (y_i - x_i)` over the anchors so far. Before the first window
   closes, `a = y - x` of the first record of the epoch.
3. **Drift regression.** With 5 or more anchors, `b` is the least-squares
   slope of `y` over `x` through the last 60 anchors (60 s), **clamped to
   1 +- 200 ppm** (`maxDriftPpm`). Then `a = min_i (y_i - b x_i)` over the
   last 10 anchors, so the line is the lower envelope of the recent
   arrivals: `host_ns` estimates the earliest time a sample taken at `x`
   could have arrived.
4. **Slew.** A new `(a, b)` is not applied as a step. The offset used for
   output moves toward the estimate by at most 500 ns per millisecond of
   controller time (500 ppm), except at an epoch start. With `b` within
   200 ppm of 1 this keeps `host_ns` strictly increasing per hand.

The result is biased late by the smallest delivery delay of the path
(controller to bridge to phone). That bias is constant for a given link and
is removed as far as it can be by the bridge anchor below.

## Bridge anchor (FF15 echo)

With echoes, the phone-to-bridge clock offset is known to within half a round
trip, and `rx_time_us` then replaces the phone arrival time as `y`:

- Each answered ping gives `offset = ((t2 - t1) + (t3 - t4)) / 2` and
  `rtt = (t4 - t1) - (t3 - t2)` ([PROTOCOL.md](PROTOCOL.md), "FF15 echo in the
  app"). Only pings whose `rtt` is within 2 ms of the smallest `rtt` of the
  last 60 s are used; the bridge offset `theta` is the median of their
  offsets, and it needs at least 5 such pings.
- With a valid `theta`, anchors use `y = rx_time_us * 1000 - theta_ns` for
  records without `RX_TIME_SYNTHETIC`, still through the 1 s min filter (on a
  Pi the filter is what removes the burst-read stamps).
- `host_ns` then estimates the time the bridge received the report, on the
  phone clock. The remaining bias is the Classic link delay (a few
  milliseconds, unknown) plus up to half the smallest round trip.
- A Pi answer has `turnaround_us` 0, so `t3 = t2`. On the WebSocket the
  `ping`/`pong` pair with `serverTimeUs` is used the same way.
- A changed `boot_id` (proposal P2), or `rx_time_us` going backwards,
  discards `theta` and all echo history for that bridge.

Without echoes the timeline stays phone-anchored. The state says which one is
in force.

## Drift

Crystal clocks differ by tens of ppm, which is why the clamp is 200 ppm. One
earlier user-reported figure does not fit that: ticks over wall-clock of
1.0016 and 1.0083 on two controllers ([STATUS.md](STATUS.md)), which is 1600
and 8300 ppm. Those came from short captures timed by phone arrival and are
probably dominated by the measurement, but that is an assumption. The first
recorded 10-minute session ([IMU_LOG.md](IMU_LOG.md)) settles it: if the
slope of the anchors is outside 200 ppm, `maxDriftPpm` is raised to cover the
measured value before the timeline is used, and this section is updated. The
snapshot exposes the unclamped slope so the condition is visible.

## Outliers

- A window whose anchor lies more than 20 ms above the current line (every
  record of that second was late: a stall) is left out of the regression and
  of the `a` minimum. It changes nothing else.
- An anchor below the line is always accepted; it means the line was too
  high.
- Three consecutive windows more than 20 ms above the line, or one anchor
  more than 50 ms below it, is a step in the path delay or in a clock: the
  anchor history is cleared, `b` is kept, and `a` is re-estimated from the
  following windows (state back to warm-up, same epoch). There is no
  threshold beyond which an offset change is refused forever.
- A record with non-finite gyro or accel still advances the timeline; only
  the fusion skips it.

## Epochs and discontinuities

An epoch is a stretch in which one `ticks64` sequence and one `(a, b)` apply.
A new epoch starts for a hand when:

1. the spec's discontinuity rule fires
   ([PROTOCOL.md](PROTOCOL.md), "Timing"): `|dt_ticks * 100 ns -
   delta(rx_time_us) * 1000 ns| > 100 ms`, or `rx_time_us` goes backwards.
   This is `TickStepKind.discontinuity`, and the timeline uses `TickTimer`'s
   decision, never a second copy of the rule;
2. a record has `TICK_RESET` set (proposal P1);
3. the hand's `controller_epoch` changes (proposal P2);
4. the bridge's `boot_id` changes (both hands);
5. two consecutive samples are more than 400 s apart by `rx_time_us`
   (unwrapping would be ambiguous).

At an epoch start `ticks64` restarts from the 32-bit value, the anchors are
cleared, `b` keeps its last value (the controller's crystal did not change),
`a` starts as in the warm-up, the slew limit does not apply to the first
sample, and the first `TimedSample` has `epochStart` set so the consumer can
reset its filter state while keeping the orientation.

Not a new epoch:

- a sequence gap, or a `dt` of many periods: ticks keep counting through lost
  reports;
- a delta above 5 s that passes rule 1 (`longGaps`);
- a phone link drop and reconnect, and a switch between BLE and WebSocket on
  the same bridge: the controller and its ticks carry on. The path delay
  changes, so the phone anchors are cleared (as for a step) and `theta` is
  kept if the bridge clock did not restart;
- the same hand appearing on another bridge: that is another timeline.

The timeline is owned by the session, not by `ControllerService`, so that
re-creating the service after a link drop does not discard it.

## Synthetic-tick modes

| Mode | When | `x` | Notes |
| --- | --- | --- | --- |
| `deviceCounter` | WMR and PSVR2 hands | the controller's ticks | everything above |
| `bridgeSynthetic` | a record has `TICKS_SYNTHETIC` (proposals P1/P4, Switch) | the bridge's synthetic ticks | `b` is then the bridge-clock rate against the phone. `rx_time_us` and the ticks are one clock, so with a valid `theta` the mapping is `host_ns = bridge time - theta` directly and the rate check `tick/clock` is meaningless |
| `rxDerived` | a Switch hand on a bridge without `SWITCH_SYNTHETIC_TICKS` (`device_ticks` is 0) | `rx_time_us * 10` | the bridge already steps `rx_time_us` back 5 ms per older sample, so it advances per record. `dt` for fusion comes from the same values. Quality is that of the bridge's receive jitter |

The mode is chosen per hand from the FF17 model and the record flags and is
part of the snapshot. A mode change starts a new epoch.

## API sketch

Pure Dart, in `wmr_core` (no Flutter, no isolates). Names are the contract
for the tests; signatures may gain optional parameters.

```dart
enum TimelineState { warmup, phoneAnchored, bridgeAnchored }

enum TickSource { deviceCounter, bridgeSynthetic, rxDerived }

class TimedSample {
  final DecodedRecord record;
  final int receivedAtUs;   // transport stamp, unchanged
  final int epoch;          // per hand, starts at 0
  final bool epochStart;    // first sample of an epoch
  final int ticks64;        // unwrapped within the epoch
  final double dtSeconds;   // from TickTimer; 0 on a baseline
  final int hostTimeNs;     // a + b * ticks64 * 100, slewed
  final int uncertaintyNs;  // half-width the timeline claims
  final TimelineState state;
}

class TimelineLinkEvent {
  // linkUp, linkDown, transportSwitch, controllerConnected,
  // controllerDisconnected, bootIdChanged, controllerEpochChanged
}

class SensorTimeline {
  SensorTimeline({required String bridgeId, TimelineConfig config});

  /// One record of this bridge, in arrival order. Never drops a record.
  TimedSample add(DecodedRecord record, int receivedAtUs);

  /// One answered ping of this bridge (FF15 or WebSocket pong).
  void addEcho({required int t1Us, required int t4Us,
      required EchoAnswer answer});

  /// Link and controller events for this bridge.
  void onLinkEvent(TimelineLinkEvent event);

  /// Per hand: state, tick source, epoch, a, b (ppm from 1, clamped and
  /// unclamped), anchors in use, residual p50/p95, theta and its age.
  TimelineSnapshot get snapshot;
}
```

`TimelineConfig` holds the constants named in this document: window 1 s,
minimum records per window 20, regression length 60 anchors, envelope length
10 anchors, `maxDriftPpm` 200, slew 500 ppm, stall threshold 20 ms, step
threshold 50 ms, echo `rtt` margin 2 ms, echo history 60 s.

`uncertaintyNs`: in warm-up, the spread of `y - x` seen so far; phone
anchored, the p95 anchor residual plus an allowance for the unknown minimum
delay (default 15 ms on BLE, 5 ms on WebSocket); bridge anchored, half the
smallest round trip plus the p95 anchor residual.

Consumers:

- `HandPipeline` keeps taking `dt` from the ticks.
- The DroidDeck sink fills `sampleTimeNs` from `hostTimeNs`. That packet
  field is on `CLOCK_MONOTONIC`, while `receivedAtUs` comes from a Dart
  `Stopwatch`; the sink converts with an offset measured once per process
  (both clocks read back to back, smallest difference of 5 tries).
- The latency recorder reports delay as `receivedAtUs * 1000 - hostTimeNs`.
- The raw IMU log records epoch changes as `timeline_epoch` events and the
  configuration in its metadata.

## Acceptance

Automated, on synthetic data (deterministic generator: 200 Hz ticks, a clock
rate error, a minimum delay, exponential jitter, batches of up to 9, 2 % of
windows stalled by 100 ms, random report loss):

| Check | Pass |
| --- | --- |
| Offset error after 10 s (true minimum delay removed) | below 1 ms |
| Slope error after 120 s with a true rate error of 50 ppm | below 10 ppm |
| Slope with a true rate error of 500 ppm | clamped at 200 ppm, and the snapshot's unclamped slope within 20 ppm of 500 |
| `hostTimeNs` per hand | strictly increasing for every sample of an epoch |
| p95 of the anchor residuals in steady state | below 3 ms |
| 20 % random report loss, no tick restart | no new epoch |
| Tick restart (the `reconnect_tick_restart` golden sequence) | a new epoch on that sample |
| The `u32_tick_wrap` golden sequence | `ticks64` equals `expected_ticks64` |
| A 100 ms step in path delay | `phoneAnchored` again within 5 s, no epoch change |
| Replay of one `.wmrimu` file twice | identical `TimedSample` sequences |
| Cost of `add` | below 5 microseconds on average on the CI host, no allocation other than the result |

On recorded data (owner-run, from a 10-minute raw IMU log on a Pi bridge with
two WMR controllers; see [TEST_PLAN_PI_WMR.md](TEST_PLAN_PI_WMR.md), M5):

| Check | Pass |
| --- | --- |
| p95 anchor residual per hand after the first 60 s | below 3 ms |
| Unclamped slope per hand | recorded; within 200 ppm of 1, or `maxDriftPpm` is revised |
| Slope stability after the first 60 s | within 20 ppm over the rest of the session |
| Time to `phoneAnchored` after a controller power-cycle | 3 s or less |
| Epoch count | one per controller power-cycle and one per bridge restart, none otherwise |
| `hostTimeNs` | strictly increasing per hand and epoch |

## Open

- The true minimum delay of each path (the constant bias) is not observable
  from these three clocks. A camera or a known mechanical event is needed to
  measure it.
- The 100 ms tolerance of rule 1 on a link that loses a fifth of its reports
  has not been tested on hardware.
- Whether the controller's tick counter restarts on a reconnect is still
  unobserved; rule 1 handles both answers.
