# Latency screen and export

Milestone 4, plus the FF15 round trip. Screen: "Latency test" on the connect screen (real device when connected, or the fake bridge). Code: `lib/services/latency_recorder.dart` (pure Dart), `lib/services/echo_client.dart`, `lib/protocol/echo.dart` (pure Dart), `lib/services/latency_files.dart`, `lib/ui/latency/`. Not verified on hardware.

## What it measures

A run listens to whichever stream the service has active (raw FF11 frames or decoded FF12 records) for 30 s, 60 s, 120 s or until Stop. It shares the service's streams; it does not subscribe again.

| Figure | Streams | Meaning |
|---|---|---|
| Inter-arrival min/p50/p90/p95/p99/max | all | Phone arrival time between distinct arrivals of one hand. Records that share a notification (batching) count as one arrival, so with batching this is the notification spacing. Stalls: inter-arrival over 50 ms |
| Sequence gaps, out of order | all | From the per-hand ESP32 sequence numbers: loss after the ESP32 numbered a report |
| Missing (ticks), period | decoded | Reports missing by the controller's own tick deltas, firmware definition (`TickTimer`). Includes loss between the controller and the ESP32, which sequence numbers cannot show |
| Delay above min | decoded | `arrival - rx_time_us` minus the smallest value in its 10 s window: time between the ESP32 receiving a report and the phone seeing it, without the fixed part. Queueing and connection-event wait show up here |
| Delay variation | decoded | `|change of arrival - rx_time_us|` between consecutive records of one hand |
| Link | all | MTU, RSSI at start and end, connection interval and PHY where the platform reports them, whether high priority was requested |
| Counters | all | How much the service's incomplete-frame, reassembly-error and parse-error counters grew during the run |

The ESP32 and phone clocks have unrelated origins and drift apart (tens of ppm), so `rx_time_us` is never compared with a phone time directly: only differences inside a 10 s window, or between consecutive records, are used. WMR_Bridge `docs/PROTOCOL.md` describes `rx_time_us` as meant for this ("the one-way part of issue #1").

## Round trip (FF15 echo)

With "Measure round trip" on (the default) and a bridge that has FF15 (WMR_Bridge #13; spec in its `docs/PROTOCOL.md`, "Echo, FF15"), the run also pings the echo characteristic about four times a second (250 ms apart, one ping outstanding at a time, 1 s timeout): about 480 pings in a 120 s run, about 120 in 30 s. It works while any stream is active, because FF15 is outside the FF11/FF12/FF14 exclusion.

| Figure | Meaning |
|---|---|
| `rtt` (min/p50/p90/p95/p99/max) | `(t4 - t1) - turnaround_us`: the spec's round trip without the time the answer waited on the ESP32. Includes the app, the plugin and its platform channel, both Bluetooth stacks and the air |
| `end_to_end` | `t4 - t1`: write call to the notification reaching the app |
| `turnaround` | Time the answer waited on the ESP32, from its reply |
| `max_queue_depth` | Largest stream backlog the answers skipped. An rtt that grows with it would mean the answer priority is not working |
| answered / timeouts / failed writes | Pings sent = answered + timeouts + failed writes. Late or duplicate answers, bad answers and pings skipped (one still waiting) are in `counters` |

`t1` is the phone time just before the write is handed to the transport, which serializes GATT operations; `t4` is the transport's timestamp of the notification. So `rtt` includes any wait behind other GATT work and the plugin's own delay, which is what an app sees. The spec's priority does not bypass notifications already handed to BTstack and the controller, so at stream load the rtt includes waiting for those.

The per-ping clock offset estimate (`((t2 - t1) + (t3 - t4)) / 2`, error up to rtt/2) is written to the echo CSV for each ping and not summarized or applied to the delay figures.

A bridge without FF15 (older firmware) is detected from service discovery before anything is subscribed: the run goes ahead without a round trip and the screen says why. If the switch is off, or no pings are used, `round_trip` in the JSON is `{"measured": false, ...}`.

Not verified on hardware: neither the firmware's FF15 nor this client has been run on a bridge. A single 24 ms turnaround seen in nRF Connect (user-reported) is not a distribution; a run from this screen is the first.

## Export

Each run is saved when it ends to `latency/` under the app documents directory, as `latency-YYYYMMDD-HHMMSS.csv` and `.json`, plus `latency-YYYYMMDD-HHMMSS-echo.csv` when the run used the echo. "Export" opens the share sheet with all of them.

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

Echo CSV, one row per answered ping (timeouts are only counted in the JSON):

```
ping_id,t1_us,t1_done_us,t4_us,end_to_end_us,esp_rx_us,turnaround_us,rtt_us,queue_depth,clock_offset_us
```

`t1_us`, `t1_done_us` (write call returned) and `t4_us` are phone time since the run started; `esp_rx_us` is the raw ESP32 clock; `clock_offset_us` is the per-ping estimate above.

JSON (format `wmr-latency`, version 2: `round_trip` is an object, percentiles gained `min_us` and `p95_us`): run metadata (`started`, `stream`, `duration_us`), `round_trip` (`measured`, and when true `rtt`, `end_to_end`, `turnaround`, `max_queue_depth`, `sent`, `answered`, `timeouts`, `failed_writes`, `counters`), `link`, `counters`, `rows_dropped`, `mode_changed`, and per hand `records`, `arrivals`, `span_us`, `rate_per_s`, `inter_arrival` and (decoded) `delay_above_window_min` / `delay_variation` as `{count, min_us, p50_us, p90_us, p95_us, p99_us, max_us}`, `stalls_over_50000us`, `sequence_gaps`, `sequence_loss`, `out_of_order`, `missing_from_ticks`, `tick_loss`, `period_us`. Fields that do not apply are `null`.

## Known limits

- Percentiles are nearest-rank over the whole run.
- A mode switch during a run sets `mode_changed`; the figures then mix two streams.
- Arrival times are stamped by the transport when the plugin delivers the notification, so they include plugin and platform-channel delay; a bare-Kotlin baseline would separate that (PLAN.md).
