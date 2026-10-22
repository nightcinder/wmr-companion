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

One earlier data point, a single 24 ms turnaround seen in nRF Connect (user-reported), was not a distribution; the first run from this screen is below.

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

## First hardware run (user-reported)

One 120 s run from the screen, 2026-10-22 14:56:31, files `latency-20261022-145631{,-echo}.csv` and `.json`. Setup as reported: FF14 stream, MTU 517, 15 ms connection interval, high priority requested, both controllers connected. RSSI was -69 dBm at the start and -48 dBm at the end, so the phone/bridge position cannot be assumed fixed. Firmware FF15 (WMR_Bridge #13) and this client are exercised on hardware for the first time here.

**FF15 round trip (479 pings, 479 answered, no timeouts, no late, bad or skipped answers):**

| ms | min | p50 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| rtt = (t4 - t1) - turnaround | 22.4 | 40.8 | 62.7 | 72.8 | 97.1 | 151.9 |
| write call to answer (t4 - t1) | 22.8 | 41.2 | 63.1 | 73.1 | 98.3 | 152.2 |
| ESP32 turnaround | 0.27 | 0.43 | 0.77 | 0.91 | 2.27 | 7.47 |

Other figures from the echo CSV (computed from the exported file, not shown by the app):
- The ESP32 queue depth the answers skipped was 0 for 118 of 479 pings, median 3, maximum 28. Median rtt by depth: 42.9 ms at depth 0, 40.6 ms at 1 to 5, 40.2 ms at 6 to 10, 76.4 ms at over 10 (only 7 pings). Correlation of rtt with depth 0.15.
- Median rtt was 40.5 ms in the first half of the run and 41.4 ms in the second.
- The write call itself (t1 to its return) took 5.0 ms at the least, 11.1 ms median, 46.7 ms at p95, 63.6 ms at most. The answer was always seen after the write call returned, but that does not mean the packet left the phone when the call returned: on 16 pings it came within 1 ms after it.

**Same run, streams (both hands, FF14):**

| | LEFT | RIGHT |
|---|---|---|
| records | 17 999 | 19 696 |
| rate (per s) | 150.1 | 164.2 |
| arrivals (notifications carrying the hand) | 4 895 | 5 031 |
| inter-arrival ms: p50 / p95 / p99 / max | 19.1 / 57.7 / 89.6 / 166.8 | 19.7 / 50.0 / 80.8 / 209.9 |
| stalls over 50 ms | 308 | 252 |
| sequence gaps | 0 | 0 |
| missing by ticks | 6 016 (25.1 %) | 4 268 (17.8 %) |
| delay above window minimum ms: p50 / p95 / max | 20.9 / 39.4 / 138.4 | 20.1 / 39.5 / 137.6 |

No incomplete frames, reassembly errors or parse errors. The tick loss figures are in the range of the other two-controller runs in STATUS.md; this run does not add to the LEFT/RIGHT loss question.

**What this shows:**
- The FF15 path works on hardware end to end: the layout, the write without response, the answers, and the app's matching. Nothing was lost on it.
- The ESP32 is not where the time goes: the answer left the ESP32 within 0.43 ms of the request at the median and within 7.5 ms at worst.
- The round trip has a floor of about 22 ms and a median of about 41 ms with a long tail. Even the fastest ping took longer than the 15 ms connection interval, so a ping and its answer spanned more than one connection event.
- The rtt does not grow with the ESP32 stream backlog the answer skipped (flat from depth 0 to 10), which is what the priority rule should give. It does not show that the priority works: notifications already handed to the controller still go ahead of an answer, and the depth is a count of queued frames, not of notifications in flight.

**What this does not show:**
- Where the 41 ms is spent. The rtt includes the app's write call (median 11 ms), the plugin and platform channel in both directions, the phone's and the ESP32's Bluetooth stacks, and the air. It is not a controller-to-screen latency, and not the latency of the stream records.
- Whether the FF14 traffic causes it. Every ping here competed with a running stream. A run with the stream off, and runs on FF12 and FF11, at the same position, are needed. The app has no stream-off mode yet.
- Anything about other phones, positions or distances; the RSSI moved by 21 dB during the run.

## Known limits

- Percentiles are nearest-rank over the whole run.
- A mode switch during a run sets `mode_changed`; the figures then mix two streams.
- Arrival times are stamped by the transport when the plugin delivers the notification, so they include plugin and platform-channel delay; a bare-Kotlin baseline would separate that (PLAN.md).
