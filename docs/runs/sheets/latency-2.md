# Run sheet: latency-2 - the Flutter app against the native GATT probe

Status: **Archived 2026-11-07: ONY-23 closed, Stay Flutter (ONY-1010).** The standalone native probe's retirement is tracked in ONY-1012. No further runs are scheduled; this sheet is the record of the rule and the two sessions that decided ONY-23.

Question (answered): of the ~41 ms FF15 round trip and the ~250-300 stalls over 50 ms per hand per 120 s, how much is `universal_ble` plus the platform channel and Dart, and how much is the radio and connection parameters?

## Verdict: Stay Flutter

ONY-23 is closed: keep `universal_ble`; do not move the BLE receive hot path to native Kotlin. `d = app p50 - probe p50`.

| Session | Pair | d | Probe stalls L/R | App stalls L/R |
|---|---|---|---|---|
| 2026-10-28 | FF14, 250 ms | +3.7 ms (39.3 vs 35.6) | 274/365 | 235/317 |
| 2026-11-07 | FF14, 250 ms, post-fix re-run | -16.3 ms (42.2 vs 58.5) | 610/698 | 490/440 |
| 2026-11-07 | FF14, 50 ms | -2.6 ms | | |
| 2026-11-07 | FF14, 1000 ms | -9.9 ms | | |

Session 1 (2026-10-28) is Stay Flutter. Session 2 (2026-11-07) is **In between** on the stall clause: `d = -16.3 ms` passes the one-sided `d <= +5 ms` clause, but the right hand's app 440 vs probe 698 stalls give `abs(a - p) = 258 > 0.25 * 698 = 174.5` (the left hand, 490 vs 610, passes at `120 <= 152.5`). Neither session reaches the Move native trigger (`d >= +10 ms`, or probe stalls `p < 0.5 * a`). The two sessions therefore do not repeat the same label, but both labels prescribe the same action: stay on Flutter and track the `universal_ble` gaps upstream (app issue #20). ONY-23 is closed on that converging prescription, not on a repeated label.

## Decision rule (amended by ONY-1010)
- **Test condition:** a normal warm/stable power state across two separate sittings. No reboot: users launch the app from a warm phone, and a cold boot hides warm-transition faults. Disconnect and reconnect between runs, which negotiates a fresh BLE link.
- **Stay Flutter** if the app's RTT p50 is at most 5 ms above the probe's (one-sided `d <= +5 ms`) AND the app's count of >50 ms stalls is within 25% of the probe's, at the same position and stream.
- **Move the receive hot path native** (behind `BleTransport`: notification receive, timestamp and FF14 parse in Kotlin, batches crossing the channel) if Flutter adds >= 10 ms at p50, OR more than half its stalls are missing in the probe.
- **In between:** stay Flutter and file the `universal_ble` gaps upstream (app issue #20).

| Rule phrase | Arithmetic |
|---|---|
| "at most 5 ms above the probe's" | `d <= 5 ms` |
| "adds >= 10 ms at p50" | `d >= 10 ms` |
| "within 25% of the probe's" | `abs(a - p) <= 0.25 * p` |
| "more than half its stalls are missing" | `p < 0.5 * a` |

Check in this order: Move if `d >= 10 ms` or either hand has `p < 0.5a`; Stay only if `d <= 5 ms` AND both hands have `abs(a-p) <= 0.25p`; otherwise In between. Only the FF14 pair decides; the no-stream pair is context. One session is not a verdict: the same outcome must repeat in a second session in the normal warm/stable power state. ONY-23 was closed on the prescription instead: session 1 was Stay Flutter and session 2 was In between on the stall clause, and both prescribe staying on Flutter.

## Archived protocol (kept for the record; the probe's retirement is tracked in ONY-1012)

### Setup, once per session
- Tape the phone stand ~**1.0 m** from the bridge; controllers face down and still ~**0.5 m** away. Photo start and end; do not move anything during the session.
- One bridge firmware commit, one app APK and one probe APK, with hashes. Same phone and Android version throughout.
- No other BLE app, Bluetooth scanning off, battery saver off, phone not charging.
- **One client at a time:** connect, confirm the `STREAM` line, run, export, disconnect.
- Settle 30 s after connecting or changing stream. Expect `mtu=517` and `conn=[15.00ms lat=...]`.
- Runs are **120 s**, pings **250 ms** in the main blocks (50/250/1000 ms in the interval pass). Let the client stop; do not press Stop.
- Record RSSI at start and end. Discard a pair if RSSI differs by more than **3 dB**, or if MTU or `lat` differs, and repeat it.
- Invalid runs (disconnect, controller sleep, missing `STREAM`, wrong mode, MTU/interval change, crash) are repeated and recorded as invalid.

### Run order
| Block | Order |
|---|---|
| 1 | App none, Probe none, App FF14, Probe FF14 |
| 2 | Probe none, App none, Probe FF14, App FF14 (reversed so drift cannot favour one client) |
| 3 | App none, Probe none, App FF14, Probe FF14 |
| Interval pass | App/Probe FF14 at 50 ms, then 250 ms, then 1000 ms |

Twelve 120 s runs (about 24 min), then six interval runs (about 12 min); plan 75-90 min with settling and exports. For a no-stream run, `STREAM` must show `stream=none` and `sub=0` during the run; for FF14, `stream=batched`, `sub=1` and a live `rate_rx`.

### Record for every run
- The exact `STREAM` line(s) at start and end: `phone`, `sub`, `stream`, `mtu`, `conn=[interval lat=... to=...]`. `universal_ble` does not report the interval or latency, so this line is the only source.
- RSSI start and end; sent/answered/timeouts/failed writes; RTT min/p50/p95/p99/max; end-to-end and turnaround p50; per-hand `stalls_over_50000us` and `sequence_gaps`; valid? and anything that moved.
- A pair is comparable only at the same `lat`. If every run shows `lat=1`, this sheet does not test the slave-latency hypothesis.

### Exports
Per run: the app `wmr-latency` v3 JSON and echo CSV, or the probe v2 JSON and echo CSV, plus the bridge `STREAM` lines. Per session: APK/probe commits, phone model and Android, bridge board and port, setup photo, the file-to-run mapping, and one line for anything that moved or was repeated. Do not send the per-record frame CSV; keep it locally.

## Outcome

Stay Flutter. ONY-23 is closed; the per-run result cells were never filled because the verdict is taken from the two recorded sessions above, and the probe's retirement is tracked in ONY-1012.
