# Run sheet: latency-2 — the Flutter app against the native GATT probe

> **Proposed sheet, not yet run.** The native GATT probe it compares against (milestone 7.1) and its CI APK do not exist yet. Nothing here is a hardware result. Every figure quoted from an earlier run is user-reported and, unless stated otherwise, comes from a single run.

Question: of the ~41 ms FF15 round trip and the ~250–300 inter-arrival stalls over 50 ms per hand per 120 s (both from single runs), how much is `universal_ble` plus the platform channel and Dart, and how much is the radio and the connection parameters? This sheet is the REF/VAR protocol that measures this app against a bare-Kotlin GATT client at one fixed position, so milestone 5 (Flutter against native) can be decided on evidence rather than on the size of the number.

Companion documents: [LATENCY.md](../../LATENCY.md) (screen, export format, and the v1 stream-against-stream run sheet), [STATUS.md](../../STATUS.md) (milestones and what has been reported on hardware), [PLAN.md](../../PLAN.md) (architecture). The 7.x references below are work items of the M7 milestone in the plan that produced this sheet; milestone 5 in STATUS is the decision they feed. The probe is 7.1: a standalone Android app under `tool/gatt_probe/`, plain `BluetoothGattCallback`, same connect sequence (MTU 517, high priority), subscribing FF14 or nothing, pinging FF15 at 50/250/1000 ms, stamping `SystemClock.elapsedRealtimeNanos()` in the callback, and exporting the **same** `wmr-latency` v2 JSON and echo CSV as this app.

## The decision rule — verbatim, fixed before any data

This text is copied unchanged from the M7 task. It was written before any app-against-probe data exists; editing it after the first run invalidates the comparison.

- **Stay Flutter** if the app's RTT p50 is within 5 ms of the probe's AND the app's count of >50 ms stalls is within 25 % of the probe's, at the same position and stream.
- **Move the receive hot path native** (behind `BleTransport`: notification receive, timestamp and FF14 parse in Kotlin, batches crossing the channel) if Flutter adds ≥ 10 ms at p50, OR more than half its stalls are missing in the probe.
- **In between:** stay Flutter and file the `universal_ble` gaps upstream (app issue #20).

The arithmetic used to apply it, and the order the branches are checked, are in §6. They are fixed here as well.

## 0. What the earlier runs already say

All figures are user-reported. Sources: [LATENCY.md](../../LATENCY.md) "First hardware run" and the M7 brief (the milestone plan that sets this task).

| Run | Stream | Pings | rtt p50 | rtt p95 | Stalls over 50 ms | Notes |
|---|---|---|---|---|---|---|
| 2026-10-22 14:56:31, 120 s | FF14 | 479 answered / 479 | 40.8 ms | 72.8 ms | LEFT 308, RIGHT 252 | RSSI −69 → −48 dBm; one phone, one position, one run |
| Earlier no-stream run | none | — | 59 ms | — | — | quoted in the M7 brief; no export is recorded in this repo yet, so treat it as context, not a documented result |

- The ESP32 is not where the round trip goes: FF15 turnaround was p50 0.43 ms, max 7.47 ms. The ~40 ms is in the app, the plugin and platform channel, both Bluetooth stacks and the air. Nothing yet separates the app's share from the radio's.
- The only app-side hint is the FF15 write call: in Flutter it took 11.1 ms at the median, 46.7 ms at p95 and 63.6 ms at most. A write without response should return faster than that, which points at plugin or queueing cost — a hint, not a finding.
- The no-stream p50 (59 ms) is higher than the FF14 one (41 ms), which is the opposite of what stream load alone would predict. One live explanation is the phone granting slave latency 1 (`lat=1` in every STREAM line): an idle ESP32 may then skip every other 15 ms event. This sheet cannot set the grant; it records it (§4).
- Every run so far is a single run, one phone, one position. The earlier FF14 run also drifted 21 dB in RSSI, so its position cannot be assumed fixed. That is why §2 tapes the setup and §3 repeats and interleaves the two clients.

## 1. Definitions used below

| Term | Meaning |
|---|---|
| App | The debug APK from this repo's CI, on the latency screen, with the export described in [LATENCY.md](../../LATENCY.md) |
| Probe | The native GATT probe (7.1), built by its own CI job, exporting the same `wmr-latency` v2 JSON and echo CSV |
| Pair | One app run and one probe run with the same stream and ping interval, at the same position, in the same block or interval set |
| Block | Four runs in a fixed order: none and FF14 on each client, alternating client (§3) |
| Cell | All valid runs of one client at one stream and ping interval in one session (four runs at FF14/250 ms, three at none/250 ms) |
| `conn` | The `conn=[interval lat=… to=…]` text from the bridge's `STREAM` line; the only place the granted interval and slave latency appear |

Only one client may be connected to the bridge at a time: the firmware serves one phone link (`phone=1`). Force-stop or disconnect the other client before the next run connects.

If the probe's export is not `wmr-latency` version 2 with a `round_trip` object and the per-hand `stalls_over_50000us` field, stop. A comparison against a different schema is not this sheet.

## 2. Setup, once per session

The position is fixed with tape before the first run and is not changed until the session ends. This is not optional: the earlier run drifted 21 dB in RSSI, which is larger than any effect this sheet is trying to measure.

- **Phone.** Tape the stand's feet to the table and mark the stand's outline. The phone sits in the stand, screen up, about **1.0 m** from the bridge. Set the run length and stream before pressing Start; do not pick the phone up, tap it, or move the cable during a run.
- **Controllers.** Mark one spot per controller on the table, about **0.5 m** from the bridge, and leave them there for the whole session, including between runs. Controllers face down and still. If one sleeps, wake it with a button press without lifting it; if it moved, repeat the run and say so. Keep both connected for the whole session.
- **Bridge.** Mark its position and keep its orientation (same side up, same antenna direction) as in the earlier runs. Dress the USB cable so it cannot tug the board.
- **Photo.** One photo of the whole setup at the start and one at the end. The position is not instrumented; the photo is the record. If the tape is lifted or the setup is rebuilt between sessions, that is a new position and the two sessions cannot be paired.
- **Builds.** One bridge firmware commit for every run (record the hash and the boot banner). One app APK and one probe APK, each with its commit hash; install both before the session. Same phone and Android version throughout.
- **Phone state.** No other BLE app running, Bluetooth scanning off, battery saver off, and the phone not charging during a run. Do not change any of these inside a pair.
- **One client at a time.** Connect the client for the run, confirm the bridge's `STREAM` line, run, export, disconnect. Use a fresh connection per run; if a reconnect fails and a run has to be repeated on the same connection, record that. The app restores the previous stream when a no-stream run ends, so disconnect it before the other client connects.
- **Settle.** After connecting or changing the stream, wait **30 s** and confirm the new state from the `STREAM` line before Start. For FF14 wait for a live `rate_rx`; for none, `stream=none` and `sub=0` are expected.
- **Runs.** **120 s**, stopped by the screen/probe itself. Do not press Stop. Pings **250 ms** in the main blocks; 50, 250 and 1000 ms in the interval pass (§3.2).
- **RSSI gate.** Record RSSI at start and end of every run. If the start RSSI of the two runs in a pair differs by more than **3 dB**, discard the pair, check that nothing moved, and repeat it. If a run drifts by more than 3 dB, note it; if the decision depends on that pair, repeat it.
- **MTU and interval gate.** Expect `mtu=517` and `conn=[15.00ms lat=… to=…]`. A pair is comparable only at the same MTU and the same interval. If they differ between the two runs, discard the pair and report what the phone granted.

## 3. Run protocol

### 3.1 Main blocks — app against probe, interleaved

Three blocks is the minimum for a session. Each block is four runs: both none runs first, then both FF14 runs, alternating the client; do not run all app runs and then all probe runs.

| Block | Order | Client | Stream | Purpose |
|---|---|---|---|---|
| 1 | 1 | App | none | App, FF15 only |
| 1 | 2 | Probe | none | Probe, FF15 only, same position |
| 1 | 3 | App | FF14 | App, streamed |
| 1 | 4 | Probe | FF14 | Probe, streamed |
| 2 | 5 | Probe | none | Reverse the client order so a slow drift is not always in the probe's favour |
| 2 | 6 | App | none | |
| 2 | 7 | Probe | FF14 | |
| 2 | 8 | App | FF14 | |
| 3 | 9 | App | none | Same order as block 1 |
| 3 | 10 | Probe | none | |
| 3 | 11 | App | FF14 | |
| 3 | 12 | Probe | FF14 | |

Twelve runs of 120 s, about 24 min of measurement, then the six interval runs below; with settling, export and reconnects, plan about 75–90 min for the session.

Why this order: each client still gets none, FF14, none, FF14, none, FF14, and the two clients are never measured one after the other in a single long block. Reversing the client order in block 2 means a monotonic drift over the session cannot systematically favour either client.

For a no-stream run, `STREAM` must show `stream=none` and `sub=0` *during* the run, not only before Start. For an FF14 run, it must show `stream=batched`, `sub=1` and a live `rate_rx`. A run where the mode is wrong is invalid; repeat it and keep the invalid row marked.

Invalid runs (disconnect, controller sleep, missing `STREAM`, wrong mode, MTU/interval change, app crash) are repeated immediately and recorded as invalid. Do not silently drop them.

### 3.2 Interval pass — 50 / 250 / 1000 ms on one pair

After the three blocks, at the same position, with FF14 selected on both clients. All six runs are one contiguous pair set, so the three interval points are not separated by the main blocks.

| Order | Client | Ping interval | Purpose |
|---|---|---|---|
| 13 | App | 50 ms | ~2400 pings in 120 s; about three pings per 15 ms event |
| 14 | Probe | 50 ms | |
| 15 | App | 250 ms | The reference point, repeated here so all three points come from one set |
| 16 | Probe | 250 ms | |
| 17 | App | 1000 ms | 120 pings in 120 s; about one ping per 67 events |
| 18 | Probe | 1000 ms | |

Six extra runs, about 12 min. The 250 ms point also exists three times per client in §3.1; if the two 250 ms figures disagree by more than the run-to-run spread, note it rather than choosing one.

Purpose: whether the RTT is quantised to the 15 ms connection interval, and whether the app and the probe show the same ladder. Compare the spacing between the clusters/modes in the distributions, not only p50. If both sides show the same ladder, the interval is not what separates them; if the app's ladder is shifted by about one interval, the difference is at least one connection event. This is interpretation, not a pass/fail threshold.

At 50 ms, a ping slower than the interval delays or skips the next one (the client keeps one ping outstanding), so the tail is under-sampled and the pings are not independent. Both clients use the same rule, so compare them like with like and do not read absolute tail percentiles at 50 ms as a distribution. At 1000 ms, 120 pings make p95/p99 coarse.

### 3.3 Repeats and the second session

- **One session is not a verdict.** All earlier data is single runs, and the run-to-run spread of this comparison is not known yet. Three blocks give at least three runs per cell (four at FF14/250 ms, with the interval pass); the same direction must repeat in a **second session on another power-up** (ideally another day) before the verdict is written up (§6).
- If the two sessions disagree, the result is **not shown**. Repeat; do not pick the session that agrees with a preference.
- If one cell has fewer than three valid runs, the result is not shown.

## 4. Every run records this — including `conn` and `lat`

For **every** run, copy the exact `STREAM` line from the bridge serial: the first one printed after the run starts and the last one before it ends. Do not summarise it and do not reconstruct `conn` from the app's `link` block; `universal_ble` does not report the granted interval or latency. Format example, not a measurement:

```
STREAM phone=1 sub=1 stream=batched mtu=517 conn=[15.00ms lat=1 to=5000ms] q=0/256 high=3 notify=1234 errors=0
```

The field that matters here is `lat`. The M7 brief's live hypothesis is that the granted slave latency of 1 lets an idle ESP32 skip every other 15 ms event, which would explain a higher no-stream RTT (p50 59 ms against 41 ms with FF14). This sheet cannot set the grant — the phone decides. So:

- Record `lat` for every run, no-stream and streamed, app and probe.
- A pair is comparable only at the same `lat`. If the two runs differ, discard the pair and repeat it; if the phone keeps granting different values, report that instead of averaging across it.
- If any run shows `lat=0`, that run is the natural control for the hypothesis, and the no-stream RTT at `lat=0` against `lat=1` is worth one line in the result.
- If every run shows `lat=1`, this sheet does **not** test the hypothesis. Do not attribute the no-stream/FF14 difference to slave latency on the strength of this data.

Per-run record:

| Field | Where it comes from |
|---|---|
| Run number, block, client, stream, ping interval | This sheet; the JSON also has `stream` and `round_trip.ping_interval_us` |
| `conn=[interval lat=… to=…]`, `mtu`, `sub`, `phone` | The exact `STREAM` line(s) |
| RSSI at start and end | JSON `link` (start/end), or the first and last `link:` line in the run's STREAM blocks |
| Sent / answered / timeouts / failed writes | JSON `round_trip` |
| RTT min / p50 / p95 / p99 / max | JSON `round_trip.rtt` |
| End-to-end p50, turnaround p50 | JSON `round_trip` (context only) |
| Stalls over 50 ms, per hand | JSON `hands[].stalls_over_50000us` (FF14 runs only) |
| Sequence gaps, per hand | JSON `hands[].sequence_gaps` (FF14 runs only) |
| Valid? and anything that moved | This sheet |

## 5. Exports and paste-back — exactly these files

Per run, from the client that produced it:

- **App:** the `wmr-latency` v2 JSON (`latency-YYYYMMDD-HHMMSS.json`) and the echo CSV (`latency-YYYYMMDD-HHMMSS-echo.csv`). "Export" in the app shares all three files; the frame CSV is not needed (see below).
- **Probe:** its `wmr-latency` v2 JSON and its echo CSV. Name the files as the probe writes them; the probe's prefix is fixed by its own task.
- **Bridge:** the `STREAM` line(s) for the run, in the thread, plus the firmware commit hash and boot banner once per session.

Per session, once:

- App APK commit and probe APK commit; phone model and Android version; bridge board and port; the setup photo.
- The run-order table with the filename mapping (timestamp → run number), so the files cannot be read out of order.
- One line for anything that moved, slept, disconnected or was repeated.

Not needed for the decision: the per-record frame CSV (up to 250 000 rows). The JSON carries the percentiles, the per-hand stall counts and the stream counters, and the echo CSV carries the individual pings. Keep the frame CSV locally in case a specific stall needs a second look. If a required file is missing, say which one; do not fill a cell from memory.

Attach the files (or a zip per session) rather than pasting hundreds of CSV rows. Both the JSON and the echo CSV are required: the JSON has the summaries, and the echo CSV is the only per-ping record, needed for the interval pass's cluster comparison. If attaching is not possible, paste the JSON's `round_trip` block and the `STREAM` lines and say which files are missing; the echo CSV must still be sent for the interval runs.

## 6. Applying the rule — fixed arithmetic

The verdict is applied **after both sessions**, and only on the FF14 pair: the no-stream pair has no stream records, so its per-hand stall counts are zero on both sides by construction and cannot satisfy the stall half of the Stay branch. The no-stream pair is context for the RTT and the `lat` question.

**RTT.** Use `round_trip.rtt.p50_us` of each run. For a cell, take the median of its three (or more) valid runs' p50 values. Compare the app cell with the probe cell from the same session, stream and position. Let `d = app p50 − probe p50`.

**Stalls.** Use `hands[].stalls_over_50000us` from the FF14 runs, per hand, because the figure is per hand. Let `a` be the app's median count and `p` the probe's median count for the same hand.

The arithmetic readings of the three branches, fixed here before the data:

| Rule phrase | Arithmetic |
|---|---|
| "within 5 ms" | `abs(d) ≤ 5 ms` |
| "Flutter adds ≥ 10 ms at p50" | `d ≥ 10 ms` |
| "within 25 % of the probe's" | `abs(a − p) ≤ 0.25 × p` |
| "more than half its stalls are missing in the probe" | `p < 0.5 × a` |

Check the branches in this order, so overlapping cases have one answer:

1. **Move** if `d ≥ 10 ms`, or if either hand has `p < 0.5 × a`.
2. **Stay** only if `abs(d) ≤ 5 ms` **and** both hands have `abs(a − p) ≤ 0.25 × p`.
3. **In between** for everything else, including 5 ms < `d` < 10 ms and a stall count outside 25 % but not more than half missing.

The stall comparison is per hand because the app reports per hand and the earlier ~250–300 stalls figure was per hand. If the wording is read differently, the rule text above is still the rule; stop and ask rather than choosing a reading after seeing the numbers.

A worked shape for the summary (no values yet):

| Check | App | Probe | Difference | Branch |
|---|---|---|---|---|
| RTT p50, FF14, session 1 | | | `d` | Move if `d ≥ 10`; Stay needs `abs(d) ≤ 5` |
| RTT p50, none, session 1 (context) | | | `d` | Not a verdict on its own |
| Stalls >50 ms, LEFT, FF14 | | | `a` vs `p` | Move if `p < 0.5a`; Stay needs `abs(a−p) ≤ 0.25p` |
| Stalls >50 ms, RIGHT, FF14 | | | `a` vs `p` | as above |
| Outcome | | | | Stay / Move / In between |

Only after the same outcome holds in session 2 is it written up for milestone 5. The write-up itself is a separate task (7.6).

## 7. Results tables (empty)

**Session:** `<date/time>` — **position:** `<distance, orientation, photo>` — **phone:** `<model, Android>` — **bridge:** `<board, port>` — **firmware:** `<sha>` — **app APK:** `<sha>` — **probe APK:** `<sha>`

### 7.1 Run and link record

| # | Block | Client | Stream | Ping ms | MTU | `conn=[…]` (interval / lat / to) | RSSI start → end | `phone`/`sub`/`stream` seen | Valid? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | App | none | 250 | | | | | | |
| 2 | 1 | Probe | none | 250 | | | | | | |
| 3 | 1 | App | FF14 | 250 | | | | | | |
| 4 | 1 | Probe | FF14 | 250 | | | | | | |
| 5 | 2 | Probe | none | 250 | | | | | | |
| 6 | 2 | App | none | 250 | | | | | | |
| 7 | 2 | Probe | FF14 | 250 | | | | | | |
| 8 | 2 | App | FF14 | 250 | | | | | | |
| 9 | 3 | App | none | 250 | | | | | | |
| 10 | 3 | Probe | none | 250 | | | | | | |
| 11 | 3 | App | FF14 | 250 | | | | | | |
| 12 | 3 | Probe | FF14 | 250 | | | | | | |
| 13 | pass | App | FF14 | 50 | | | | | | |
| 14 | pass | Probe | FF14 | 50 | | | | | | |
| 15 | pass | App | FF14 | 250 | | | | | | |
| 16 | pass | Probe | FF14 | 250 | | | | | | |
| 17 | pass | App | FF14 | 1000 | | | | | | |
| 18 | pass | Probe | FF14 | 1000 | | | | | | |

### 7.2 Round trip and stream figures

| # | Sent / answered / timeouts | RTT min / p50 / p95 / max | E2E p50 | Stalls LEFT / RIGHT | Seq gaps L / R | Notes |
|---|---|---|---|---|---|---|
| 1 | | | | — / — | — / — | |
| 2 | | | | — / — | — / — | |
| 3 | | | | | | |
| 4 | | | | | | |
| 5 | | | | — / — | — / — | |
| 6 | | | | — / — | — / — | |
| 7 | | | | | | |
| 8 | | | | | | |
| 9 | | | | — / — | — / — | |
| 10 | | | | — / — | — / — | |
| 11 | | | | | | |
| 12 | | | | | | |
| 13 | | | | | | |
| 14 | | | | | | |
| 15 | | | | | | |
| 16 | | | | | | |
| 17 | | | | | | |
| 18 | | | | | | |

### 7.3 Per-cell summary

| Stream | Client | Valid runs | RTT p50 median | RTT p95 median | Stalls LEFT median | Stalls RIGHT median |
|---|---|---|---|---|---|---|
| FF14 | App | | | | | |
| FF14 | Probe | | | | | |
| none | App | | | | — | — |
| none | Probe | | | | — | — |

### 7.4 Files

| # | Client | JSON file | Echo CSV file | `STREAM` line pasted? |
|---|---|---|---|---|
| 1 | App | | | |
| 2 | Probe | | | |
| 3 | App | | | |
| 4 | Probe | | | |
| 5 | Probe | | | |
| 6 | App | | | |
| 7 | Probe | | | |
| 8 | App | | | |
| 9 | App | | | |
| 10 | Probe | | | |
| 11 | App | | | |
| 12 | Probe | | | |
| 13 | App | | | |
| 14 | Probe | | | |
| 15 | App | | | |
| 16 | Probe | | | |
| 17 | App | | | |
| 18 | Probe | | | |

### 7.5 Interval pass

| Ping ms | Client | Valid runs | RTT p50 | RTT p95 | Cluster spacing (approx.) | Stalls LEFT / RIGHT |
|---|---|---|---|---|---|---|
| 50 | App | | | | | |
| 50 | Probe | | | | | |
| 250 | App | | | | | |
| 250 | Probe | | | | | |
| 1000 | App | | | | | |
| 1000 | Probe | | | | | |

## 8. What this can and cannot show

**Can show, if the runs are valid:**

- Whether the app's RTT p50 differs from a bare-Kotlin GATT client's at the same position, stream and connection parameters, and by how much.
- Whether the app has more, fewer or the same >50 ms inter-arrival stalls than the probe on FF14, per hand.
- Whether the RTT quantises to the 15 ms connection interval the same way on both clients (interval pass).
- Whether the granted `lat` was the same in the compared runs, and whether a `lat=0` run ever occurred to test the slave-latency hypothesis.
- The size of the app's total latency against a bare-Kotlin client at this position and phone, as a bound in either direction. It does not say whether the difference is the plugin, the platform channel, Dart or the app's own queueing; that needs the native port or instrumentation.

**Cannot show:**

- Where inside the app the time goes, beyond "the probe is lower/higher by x ms".
- Anything about another phone, Android version, distance or controller position.
- Anything about iOS.
- Tracking quality, loss on the Classic links, or the multi-bridge topology of M6.
- That the app is optimal because the probe is not faster: a negative result bounds the overhead under these conditions, it does not prove there is none.

**No hardware claim is made in this file.** Nothing here is verified until Nick reports a session, with the files listed in §5, and even then it is a user-reported result, not an agent-run measurement.

## 9. Two-bridge pass (later, not this sitting)

M6 may adopt two bridges, one controller each. The hot path that ships would then carry two BLE links, so 7.5 repeats this protocol on that topology rather than assuming the one-bridge result transfers.

That pass is not part of the session above. It needs:

- the M6 pass and the app's per-bridge latency export (7.3), so per-bridge RTT and `link` are in the JSON;
- a probe build that can hold two GATT connections and export per-bridge figures (the optional two-bridge extension of 7.1). If the probe cannot do two links concurrently, the pass has no like-for-like baseline; report that and do not decide milestone 5 from the one-bridge result alone.

The protocol, repeats, `conn` record, exports and decision rule are the same, applied **per bridge** and with the worse bridge deciding. One bridge at a time is not a substitute: the phone's two links share one controller and one host stack, which is exactly what the pass is for.

## Known limits

- The probe is specified but not built. This sheet is written against the 7.1 definition; if the built probe's timestamps or JSON differ, the sheet is updated **before** the first run, not after.
- The app timestamps `t4` at the transport's notification delivery; the probe timestamps in the GATT callback. Both measure what their client sees, and the difference between them is part of what this sheet measures. It is not a pure plugin measurement.
- `t1` is taken just before the write is handed to each client's transport, so both figures include their own GATT queueing. The write call's duration is reported in the echo CSV as `t1_done_us − t1_us`; a large app-side write call with a small probe-side one is a separate hint, not the decision.
- The FF15 pings share the radio with the stream. At 50 ms the ping load is about 20 writes/s against a ~160 records/s stream; it is small but not zero, which is why the main blocks stay at 250 ms.
- `lat` is the phone's grant, not something either client sets. The no-stream/slave-latency hypothesis is only tested if a `lat=0` run occurs; otherwise it stays a hypothesis.
- One phone, one bridge, one position per session. The second session is a repeat on another power-up, not another phone or position.
- The decision rule's thresholds are fixed. This sheet adds no tolerance and no post-hoc adjustment; it only says how the fixed words are read arithmetically and which run counts.
