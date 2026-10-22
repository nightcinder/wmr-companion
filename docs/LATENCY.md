# Latency screen and export

Milestone 4. Screen: "Latency test" on the connect screen (real device when connected, or the fake bridge). Code: `lib/services/latency_recorder.dart` (pure Dart), `lib/services/latency_files.dart`, `lib/ui/latency/`. Not verified on hardware.

## What it measures

A run listens to whichever stream the service has active (raw FF11 frames or decoded FF12 records) for 30 s, 60 s, 120 s or until Stop. It shares the service's streams; it does not subscribe again.

| Figure | Streams | Meaning |
|---|---|---|
| Inter-arrival p50/p90/p99/max | all | Phone arrival time between distinct arrivals of one hand. Records that share a notification (batching) count as one arrival, so with batching this is the notification spacing. Stalls: inter-arrival over 50 ms |
| Sequence gaps, out of order | all | From the per-hand ESP32 sequence numbers: loss after the ESP32 numbered a report |
| Missing (ticks), period | decoded | Reports missing by the controller's own tick deltas, firmware definition (`TickTimer`). Includes loss between the controller and the ESP32, which sequence numbers cannot show |
| Delay above min | decoded | `arrival - rx_time_us` minus the smallest value in its 10 s window: time between the ESP32 receiving a report and the phone seeing it, without the fixed part. Queueing and connection-event wait show up here |
| Delay variation | decoded | `|change of arrival - rx_time_us|` between consecutive records of one hand |
| Link | all | MTU, RSSI at start and end, connection interval and PHY where the platform reports them, whether high priority was requested |
| Counters | all | How much the service's incomplete-frame, reassembly-error and parse-error counters grew during the run |

The ESP32 and phone clocks have unrelated origins and drift apart (tens of ppm), so `rx_time_us` is never compared with a phone time directly: only differences inside a 10 s window, or between consecutive records, are used. WMR_Bridge `docs/PROTOCOL.md` describes `rx_time_us` as meant for this ("the one-way part of issue #1").

**Not measured: true round trip.** That needs an echo from the bridge (WMR_Bridge issue #1). A proposal is open there; this screen does not use it until it is in the firmware's `docs/PROTOCOL.md`. The JSON's `round_trip` field says so.

## Export

Each run is saved when it ends to `latency/` under the app documents directory, as two files with the same stem `latency-YYYYMMDD-HHMMSS`. "Export CSV + JSON" opens the share sheet with both.

CSV, one row per frame or record (up to 250 000 rows; more are counted in `rows_dropped` but still in the summary):

```
hand,sequence,arrival_us,inter_arrival_us,seq_delta,device_ticks,device_dt_us,esp_rx_us
LEFT,1,0,,,1000,,1000000
LEFT,2,10000,10000,1,101000,10000,1010000
```

- `arrival_us`: phone monotonic time since the run started.
- `inter_arrival_us`: since the previous distinct arrival of this hand; `0` when the record shares a notification with the previous one; empty for the first.
- `seq_delta`: sequence change from the previous record of this hand (1 is normal).
- `device_ticks`, `device_dt_us`, `esp_rx_us`: decoded streams only; `device_dt_us` is the tick step in microseconds (empty for a baseline or discontinuity). `esp_rx_us` is the raw ESP32 clock: do not subtract it from `arrival_us`.

JSON (format `wmr-latency`, version 1): run metadata (`started`, `stream`, `duration_us`, `round_trip`), `link`, `counters`, `rows_dropped`, `mode_changed`, and per hand `records`, `arrivals`, `span_us`, `rate_per_s`, `inter_arrival` and (decoded) `delay_above_window_min` / `delay_variation` as `{count, p50_us, p90_us, p99_us, max_us}`, `stalls_over_50000us`, `sequence_gaps`, `sequence_loss`, `out_of_order`, `missing_from_ticks`, `tick_loss`, `period_us`. Fields that do not apply are `null`.

## Known limits

- Percentiles are nearest-rank over the whole run.
- A mode switch during a run sets `mode_changed`; the figures then mix two streams.
- Arrival times are stamped by the transport when the plugin delivers the notification, so they include plugin and platform-channel delay; a bare-Kotlin baseline would separate that (PLAN.md).
