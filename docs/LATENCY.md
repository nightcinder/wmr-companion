# Latency screen and export

Milestone 4, plus the FF15 round trip. Screen: "Latency test" on the connect screen (real device when connected, or the fake bridge). Code: `packages/wmr_core/lib/services/latency_recorder.dart` (pure Dart), `packages/wmr_core/lib/services/echo_client.dart`, `packages/wmr_core/lib/protocol/echo.dart` (pure Dart), `packages/wmr_core/lib/services/latency_files.dart`, `apps/wmr_companion_app/lib/ui/latency/`. Not verified on hardware.

## What it measures

Before a run the screen selects **None / FF11 raw / FF12 decoded / FF14 batched** and applies it through `ControllerService.setMode` (the same API the Connect and Debug screens use; the UI never writes CCCDs). The default selection is the stream the service already has active, so a run started without touching the selector behaves as before. It shares the service's streams; it does not subscribe again.

**None** turns the active stream off through the service (FF11, FF12 and FF14 all off) and leaves only FF15 pings. The stream figures section then says "no stream" and reports no stream numbers. The mode that was active before the screen turned it off is restored when the run ends, when it is stopped, or when the screen is left mid-run. Selecting a stream again cancels that restore.

A run lasts 30 s, 60 s, 120 s or until Stop. The ping interval is 50, 250 (default) or 1000 ms; one ping is outstanding at a time. A 120 s run is about 2400, 480 or 120 pings. Intervals other than 250 ms are new and not yet run on hardware.

| Figure | Streams | Meaning |
|---|---|---|
| Inter-arrival min/p50/p90/p95/p99/max | all | Phone arrival time between distinct arrivals of one hand. Records that share a notification (batching) count as one arrival, so with batching this is the notification spacing. Stalls: inter-arrival over 50 ms |
| Sequence gaps, out of order | all | From the per-hand ESP32 sequence numbers: loss after the ESP32 numbered a report |
| Missing (ticks), period | decoded | Reports missing by the controller's own tick deltas, firmware definition (`TickTimer`). Includes loss between the controller and the ESP32, which sequence numbers cannot show |
| Delay above min | decoded | `arrival - rx_time_us` minus the smallest value in its 10 s window: time between the ESP32 receiving a report and the phone seeing it, without the fixed part. Queueing and connection-event wait show up here |
| Delay variation | decoded | `|change of arrival - rx_time_us|` between consecutive records of one hand |
| Link, per bridge | all | One row per bridge (keyed by the transport device id): MTU, RSSI at start and end, connection interval and PHY where the platform reports them, whether high priority was requested. The debug and latency screens also show that bridge's rate and loss |
| Counters | all | How much the service's incomplete-frame, reassembly-error and parse-error counters grew during the run |

The ESP32 and phone clocks have unrelated origins and drift apart (tens of ppm), so `rx_time_us` is never compared with a phone time directly: only differences inside a 10 s window, or between consecutive records, are used. WMR_Bridge `docs/PROTOCOL.md` describes `rx_time_us` as meant for this ("the one-way part of issue #1").

## Round trip (FF15 echo)

With "Measure round trip" on (the default) and a bridge that has FF15 (WMR_Bridge #13; spec in its `docs/PROTOCOL.md`, "Echo, FF15"), the run also pings the echo characteristic (250 ms apart by default; 50, 250 or 1000 ms can be selected, one ping outstanding at a time, 1 s timeout): about 480 pings in a 120 s run at 250 ms. It works while any stream is active and in no-stream mode, because FF15 is outside the FF11/FF12/FF14 exclusion.

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

CSV, one row per frame or record (up to 250 000 rows; more are counted in `rows_dropped` but still in the summary). Since format version 3 every row names the bridge; a no-stream run has only the header:

```
hand,bridge_id,sequence,arrival_us,inter_arrival_us,seq_delta,device_ticks,device_dt_us,esp_rx_us
LEFT,fake-wmr-bridge-left,1,0,,,1000,,1000000
LEFT,fake-wmr-bridge-left,2,10000,10000,1,101000,10000,1010000
```

- `bridge_id`: transport device id of the bridge that delivered the frame or record.
- `arrival_us`: phone monotonic time since the run started.
- `inter_arrival_us`: since the previous distinct arrival of this hand; `0` when the record shares a notification with the previous one; empty for the first.
- `seq_delta`: sequence change from the previous record of this hand (1 is normal).
- `device_ticks`, `device_dt_us`, `esp_rx_us`: decoded streams only; `device_dt_us` is the tick step in microseconds (empty for a baseline or discontinuity). `esp_rx_us` is the raw ESP32 clock: do not subtract it from `arrival_us`.

Echo CSV, one row per answered ping (timeouts are only counted in the JSON):

```
ping_id,t1_us,t1_done_us,t4_us,end_to_end_us,esp_rx_us,turnaround_us,rtt_us,queue_depth,clock_offset_us
```

`t1_us`, `t1_done_us` (write call returned) and `t4_us` are phone time since the run started; `esp_rx_us` is the raw ESP32 clock; `clock_offset_us` is the per-ping estimate above.

JSON (format `wmr-latency`, version 3: `link` is keyed by bridge id, hand summaries name their bridge, and the CSV gained `bridge_id`): run metadata (`started`, `stream`, `duration_us`), `round_trip` (`measured`, and when true its `bridge_id`, `rtt`, `end_to_end`, `turnaround`, `max_queue_depth`, `sent`, `answered`, `timeouts`, `failed_writes`, `counters`, `ping_interval_us`), `link`, `counters`, `rows_dropped`, `mode_changed`, and per hand `bridge_id`, `bridge_records`, `records`, `arrivals`, `span_us`, `rate_per_s`, `inter_arrival` and (decoded) `delay_above_window_min` / `delay_variation` as `{count, min_us, p50_us, p90_us, p95_us, p99_us, max_us}`, `stalls_over_50000us`, `sequence_gaps`, `sequence_loss`, `out_of_order`, `missing_from_ticks`, `tick_loss`, `period_us`. Fields that do not apply are `null`.

`link` is an object keyed by bridge id (the transport device id). Each value keeps the fields of the old single link: `mtu`, `rssi_start_dbm`, `rssi_end_dbm`, `connection_interval_us`, `phy`, `high_priority_requested`. A bridge that was connected all run has one entry; a no-stream run still has entries (the links exist even when FF11/FF12/FF14 are off).

`hand.bridge_id` is the bridge that fed that hand during the run. `hand.bridge_records` counts records per bridge id, so a hand that moved between bridges is not hidden: normally one entry, more after a swap. The FF15 round trip still pings one bridge (the service's primary device); `round_trip.bridge_id` names it.

Version 2 files from earlier runs are not read by this app: it lists and shares saved runs, and has no JSON loader to keep compatible. They remain valid `wmr-latency` v2 documents for other tools.

`stream` is `"none"`, `"raw"`, `"decoded"` or `"batched"`. A no-stream run still has the `hands` array (all counters zero), so the schema is the same for every mode.

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
- Whether the FF14 traffic causes it. Every ping here competed with a running stream. Runs with no stream, FF11, FF12 and FF14 at one fixed position are now possible from this screen (selector and no-stream mode built, **not yet run on hardware**); the run sheet below is for them.
- Anything about other phones, positions or distances; the RSSI moved by 21 dB during the run.

## Run sheet: no stream, FF11, FF12, FF14 at a fixed position (**not yet run**)

Status: **not yet run on hardware.** This is the procedure for the comparison; nothing below is a hardware result. The screen and exports are built and unit/widget tested only.

**Setup, once per session**

- Same bridge firmware for every run; write down its commit hash. Same phone and app build (the CI debug APK's commit). Note the phone model and Android version.
- Phone and ESP32 **fixed about 1.0 m apart**, phone on a stand, not moved between runs. Put both controllers on marked spots on the table, about 0.5 m from the bridge and not moved between runs; keep them awake and connected.
- Connect, then check the Connect screen: MTU (expect 517), high connection priority, and any connection-interval readout. Note RSSI at the start of each run; if it moves more than a few dB, say so.
- Latency screen: echo on, **250 ms** ping interval, **120 s** run length, select the stream, start, leave the phone alone, let it stop by itself.

**Runs, in this order**

| # | Stream | Purpose |
|---|---|---|
| 1 | None | FF15 only: no stream load at all |
| 2 | FF11 raw | Raw fragmented frames |
| 3 | FF12 decoded | One record per notification |
| 4 | FF14 batched | Several records per notification (app default) |
| 5 | None (repeat) | Run-to-run spread and RSSI drift |
| 6 | FF14 batched (repeat) | Run-to-run spread for the busiest stream |

For each run: wait for the mode switch to finish before Start; at the end use **Export CSV + JSON + echo**; note the run number and the stream next to the exported files. Do not change the selector during a run (the screen disables it).

**What to send back**

- All three files per run (`.csv`, `.json`, `-echo.csv`), or at least the JSON and echo CSV. The JSON `stream` field says which mode it was; the timestamped filename keeps the order.
- Firmware hash, app commit, phone model/Android version, MTU, connection interval and high-priority result from the report, and RSSI at start/end.
- Any mode fault shown on screen, and anything that moved during the session.

**What the runs can show, if they work**

- `rtt` with no stream against each stream: whether the ~40 ms is caused by stream load or is there even with FF15 alone.
- Whether `rtt` changes with the notification count (FF12 against FF14) at the same position.
- The optional 50 ms and 1000 ms ping intervals, if run, whether `rtt` is quantised to the connection interval. They are not part of the six runs above.

Six runs is one position, one phone, one session. The two repeats are there so a difference smaller than the run-to-run spread is not called a result. Nothing here is "verified" until Nick reports it.

**Next: latency-2, the app against the native probe.** The comparison that decides milestone 5 is not stream against stream but this app against a bare-Kotlin GATT client, with the decision rule fixed before the data: [runs/sheets/latency-2.md](runs/sheets/latency-2.md). It is not yet run, and the probe it needs (milestone 7.1) is not built yet.

## Flutter library / iOS v1 run (phase 5)

The library package split is merged through phase 4. Phase 5 is the first real
iOS evidence and needs a device; it is not a CI-only result.

**Status: not run — waived by the owner on 2026-10-23 (ONY-41) for the `0.1.0`
release line.** The steps below stay the sheet for any release that claims iOS
support; this release does not have that evidence.

1. **Example app, both platforms.** `cd example && flutter run -d <device>`.
   It shows a live stick/trigger/button sample from the fake bridge; this
   proves the package builds and the UI wiring works on the platform.
2. **Real bridge, both platforms.** Replace `FakeTransport` with
   `UniversalBleTransport`, grant the Bluetooth permission (the example
   manifest/Info.plist already declare it), and confirm FF14 samples in the
   example. Then run the full app and connect on iOS 18.
3. **Latency, iOS and Android.** Use the existing Latency screen and the six
   runs above on each platform. Record the exported JSON/echo files, firmware
   hash, app commit, phone model, iOS version and whether MTU/RSSI are
   visible.
4. **Decision.** Apply the fixed rule in [runs/sheets/latency-2.md](runs/sheets/latency-2.md):
   if `universal_ble` meets the latency/background requirement, phase 6 (the
   native iOS transport) never runs; if not, the numbers decide it. Record
   the outcome here and in `docs/STATUS.md`.

No iOS device run has happened yet; until then iOS is design- and
CI-config-validated, not a hardware claim.

## Known limits

- Percentiles are nearest-rank over the whole run.
- A mode switch during a run sets `mode_changed`; the figures then mix two streams.
- Arrival times are stamped by the transport when the plugin delivers the notification, so they include plugin and platform-channel delay; a bare-Kotlin baseline would separate that (PLAN.md).
