# Test plan: Raspberry Pi bridge with WMR controllers

Scope: the one scenario the owner has put first, the companion app working
end to end against a Raspberry Pi bridge with two WMR controllers. ESP32,
PSVR2, Switch and headset tracking are out of scope except where a spec item
(S1-S5) touches them.

Status of this plan: written 2026-11-13. **No row marked "owner-run hardware
test" has a recorded result.** When one is run, its result is entered as
user-reported with the date, the board, the phone and the build, and the
figure is not generalised beyond that sitting.

How to read it:

- **Automated** rows run without hardware, in CI or on a developer machine.
  "exists" means the test is in the tree today; "to write" means it is
  planned with the milestone; "in review" means it is part of a patch that is
  not merged.
- **Owner-run hardware test** rows need the Pi, the two controllers and the
  phone. They are run by the project owner; nobody else has the hardware.
- A milestone is done when every automated row passes and every owner-run
  row has a recorded pass. A row that cannot be measured with the tools that
  exist names the missing tool.

Reference documents: WMR_Bridge `docs/PI_BRIDGE.md` (checklist P1-P14 and the
run sheet `docs/runs/sheets/bench.md`), [PROTOCOL.md](PROTOCOL.md),
[IMU_LOG.md](IMU_LOG.md), [TIMELINE.md](TIMELINE.md), [GAMEPAD.md](GAMEPAD.md).
Shared vectors: `packages/wmr_core/test/fixtures/wmr_golden_v1.json`
(identical to WMR_Bridge PR #238 (branch docs/spec-patches, not yet merged) `tests/vectors/wmr_golden_v1.json`).

Record for every hardware sitting: Pi model, OS image and kernel, BlueZ
version, bridge package version, Wi-Fi band and channel, phone model and OS,
app version and build, distance and position of the controllers. Controller
addresses and the session token are never written into a sheet.

## Overview

| Id | Milestone | Depends on | Code state |
| --- | --- | --- | --- |
| M1 | Pi bring-up: pair, stream, probe | - | Pi daemon merged, host-tested |
| M2 | Decode CPU on the target board | M1 | fast decoder in review (separate PR) |
| M3 | Non-blocking `0x06` enable | M1 | in review (separate PR) |
| M4 | App end to end: WebSocket, BLE fallback, failover | M1 | app transports merged, host-tested |
| M5 | Raw IMU recorder | M4 | specified, not implemented ([IMU_LOG.md](IMU_LOG.md)) |
| M6 | DroidDeck output with sample time | M4, timeline | sink merged; `sampleTimeNs` from the timeline specified, not implemented |
| S1 | Record flag bits 1-3 | spec | specified, not implemented |
| S2 | `boot_id`, `controller_epoch`, `features` | spec | specified, not implemented |
| S3 | Echo version 2 (transmit time) | S2 | specified, not implemented |
| S4 | Switch timing contract | S1 | specified, not implemented; secondary |
| S5 | Switch 44-byte calibration blob | S2 | specified, not implemented; secondary |

S1-S5 are the protocol proposals P1-P5 of WMR_Bridge PR #238 (branch `docs/spec-patches`, not yet merged), `docs/PROTOCOL.md`
("Proposals"), in the same order.

## M1. Pi bring-up

Goal: both controllers pair to the Pi unattended and stream over the
WebSocket at the expected rate with no bridge-side errors.

### Automated

| Test | Where | State | Pass |
| --- | --- | --- | --- |
| Pi host suite | WMR_Bridge `pi/run_tests.sh` | exists | all tests pass |
| Golden vectors, Pi side | WMR_Bridge PR #238 (branch docs/spec-patches, not yet merged) `pi/tests/test_golden_vectors.py` | exists | passes: decoder state, 56-byte records, fragments, batch, echo, timing rules |
| Golden vectors, app side | `packages/wmr_core/test/golden_vectors_test.dart` | run: dart format and dart analyze clean; dart test passes (51 tests in packages/wmr_core, run on ixhel; CI build job passed on 6024d34, the head before this commit) | passes in `dart test` |
| The two copies of the vector file are identical | CI step comparing SHA-256 across the repositories | to write | equal |
| Replay smoke | `python3 -m wmr_bridge --replay ../samples/controller_frames.txt` with `tools/wifi_probe.py --stream batched --duration 10` | exists | about 160 rec/s, `sequenceGaps` 0, `dropped` 0 |

### Owner-run hardware tests

| Id | Procedure | Pass |
| --- | --- | --- |
| M1-H1 | Start from both controllers unpaired. Put LEFT in pairing mode. Repeat for RIGHT | each hand is paired, trusted and connected without operator action **within 60 s** of entering pairing mode (PI_BRIDGE P11) |
| M1-H2 | `wmr-bridge --list` | two hidraw nodes, mapped to LEFT and RIGHT |
| M1-H3 | `python3 tools/wifi_probe.py --host <pi> --token-file <file> --stream batched --duration 60`, both controllers held and moving | per hand `recordsPerSecond` **150 to 180**; `serverStatus.hands[].errors` **0** for both hands; `dropped` 0; the probe exits normally |
| M1-H4 | Same run | per hand `lossPct` and `periodMs` recorded (no pass bar here: upstream loss is a measurement, PI_BRIDGE P6) |
| M1-H5 | `iw dev wlan0 link` during the run | band recorded; on 5 GHz for the reference result |

## M2. Decode CPU

Goal: the daemon leaves headroom on the target board with both hands
streaming to one batched client.

### Automated

| Test | Where | State | Pass |
| --- | --- | --- | --- |
| Fast decoder equals the reference bit for bit | WMR_Bridge `pi/tests/test_decode.py` (`FastDecodeParityTests`: all 4096 stick values, random reports, IMU edges) | in review | passes |
| Golden vectors unchanged by the fast decoder | `pi/tests/test_golden_vectors.py` (WMR_Bridge PR #238 (branch docs/spec-patches, not yet merged)) | exists | passes before and after the patch with the same vector file |
| Decode micro-benchmark | WMR_Bridge `pi/tools/bench_decode.py` | in review | prints microseconds per report for the reference and the fast path; no fixed bar on a developer machine |

### Owner-run hardware tests

| Id | Procedure | Pass |
| --- | --- | --- |
| M2-H1 | On the target board, both controllers streaming, one `batched` probe client for 10 minutes. Sample the daemon's CPU every 10 s (`pidstat -p <pid> 10` or `top -b -d 10 -p <pid>`) | mean CPU of the daemon process **below 25 % of one core** over the 10 minutes, and no 10 s sample above 50 % |
| M2-H2 | `python3 tools/bench_decode.py` on the board | microseconds per report recorded for both decoders |
| M2-H3 | `vcgencmd get_throttled` before and after M2-H1 (Raspberry Pi boards) | `0x0` both times |
| M2-H4 | The M1-H3 probe during M2-H1 | still passes M1-H3 |

M2-H1 is run once with the merged decoder as the baseline and once with the
fast decoder, so the change is a measured difference on the same board.

## M3. Non-blocking enable

Goal: sending the `0x06` enable pair (at connect and as the 10 s keep-alive)
does not stall the stream. Today the daemon sleeps 10 ms on its event loop
between the two reports (`HidrawReader.send_enable`).

### Automated

| Test | Where | State | Pass |
| --- | --- | --- | --- |
| The enable pair is sent without blocking the event loop; the second report is scheduled, coalesced and cancelled on close | WMR_Bridge `pi/tests/test_bluez.py` (`HidrawReaderAsyncEnableTests`, part of the patch) | in review | passes |
| Keep-alive, idle sleep and wake behaviour unchanged | existing `pi/tests/test_bluez.py`, `test_bridge.py` | exists | pass with the patch applied |

### Owner-run hardware tests

| Id | Procedure | Pass |
| --- | --- | --- |
| M3-H1 | 120 s batched stream, both hands. Measure the time between consecutive WebSocket messages at the client | **no recurring inter-message gap above 15 ms at the 10 s keep-alive period**: at most 1 of the 12 keep-alive instants in the run coincides (within 100 ms) with a gap above 15 ms |
| M3-H2 | Same run with the merged code as the baseline | the periodic gap, if any, is recorded so the change is a measured difference |
| M3-H3 | Leave both controllers streaming for 15 minutes with motion every minute | no hand stops streaming; `reports` rises throughout |

Tool gap: `wifi_probe.py` reports rates, gaps and RTT but not inter-message
times. M3-H1 needs either a small addition to the probe (per-message arrival
times or a gap histogram in `--json-out`; not written) or the app's Latency
screen, whose inter-arrival figures and stall count (over 50 ms) are too
coarse for a 15 ms bar. The probe addition is part of M3.

## M4. App end to end, WebSocket and BLE failover

Goal: the app connects to the Pi, streams over the WebSocket, falls back to
BLE when Wi-Fi goes away, upgrades back, and its loss accounting agrees with
the daemon's.

### Automated

| Test | Where | State | Pass |
| --- | --- | --- | --- |
| Composite transport: TCP first, BLE fallback, upgrade back, session token from the session document | `packages/wmr_companion/test/composite_transport_test.dart` | exists | passes |
| Upgrade attempt cannot run while a route switch or a BLE recovery is in progress (no second TCP connection, no stale route) | same file | to write | passes |
| WebSocket transport: handshake, auth, subscribe, queue accounting | `packages/wmr_ws/test/` | exists | passes |
| Records dropped by the app's own receive queue are counted in the loss figures | `packages/wmr_ws/test/`, `packages/wmr_core/test/controller_service_test.dart` | to write | a forced queue drop appears in the per-hand loss |
| Sequence and tick accounting on golden timing sequences | `golden_vectors_test.dart` | run; passes (dart test in packages/wmr_core: 51 tests, run on ixhel) | passes |
| Loopback end to end: Pi daemon in `--replay` on the developer machine, app test client subscribed over `ws://127.0.0.1` | integration test | to write | records received equal the daemon's `delivered` for the session |

### Owner-run hardware tests

| Id | Procedure | Pass |
| --- | --- | --- |
| M4-H1 | Fresh install, scan, pair, connect to the Pi. Both controllers streaming in the debug screen for 2 minutes | orientation follows both controllers; rate per hand 150 to 180 Hz; no fault banner |
| M4-H2 | While streaming over Wi-Fi, switch the phone's Wi-Fi off | **BLE takes over in under 2.5 s** (time from the last WebSocket record to the first BLE record, from the app log or the raw IMU log once M5 exists); the longest pause between delivered records is under 3 s (PI_BRIDGE P12); sequence numbers continue |
| M4-H3 | Switch Wi-Fi back on | the stream **upgrades back to the WebSocket** without user action, within 10 s of Wi-Fi being connected; no duplicate or out-of-order records across the switch; the BLE HID link stays up |
| M4-H4 | Power-cycle one controller while streaming | the hand reappears without touching the app; **its sequence numbers continue** from where they were (no restart at 1); the other hand is unaffected; the app shows one tick discontinuity for that hand at most |
| M4-H5 | 10-minute session on Wi-Fi. At the end read the daemon's `status` (per hand `delivered`, `dropped`, `sequence`) and the app's per-hand counters (records, sequence gaps) | **the app's loss is within 1 % of the daemon's counters** per hand: `abs(app_records - daemon_delivered_to_this_client) <= 0.01 * daemon_delivered_to_this_client`, and the app's sequence-gap count matches the daemon's `dropped` for that client within the same 1 % |
| M4-H6 | Background the app for 30 s, return | the stream resumes without a manual reconnect; no crash |
| M4-H7 | Repeat M4-H2 and M4-H3 five times in one session | every repetition passes; no leaked connection (the daemon's `clients` returns to 1) |

M4-H5 needs the daemon counters for the app's own connection; `status`
reports per-hand totals over all clients, so the run uses the app as the only
client.

## M5. Raw IMU recorder

Goal: the recorder of [IMU_LOG.md](IMU_LOG.md) stores every record the app
receives without disturbing the stream, and a recording replays exactly.

### Automated (all to write with the implementation)

| Test | Pass |
| --- | --- |
| Header and metadata round trip, CRC, padding | bytes match a committed golden file |
| Every golden `record_hex` written as `IMU` and read back | identical bytes and `received_at_us` |
| Unknown record type is skipped by `len` | the following records are read |
| Truncated tail (cut inside a record) | reader stops at the last complete record and reports the offset, no exception |
| Rotation at the size and the time limit | segments share `session_id`, `segment_index` rises, no record is split or lost |
| Bounded queue with a stalled writer | the receive path never blocks; dropped records are counted and a `writer_drop` event appears |
| Flush cadence | data is on disk within 250 ms or 64 KiB |
| Cap | recording stops with `cap_reached` and a final `STATS`; no file is deleted |
| Replay determinism | two replays of one file give identical `TickTimer` steps and counters |
| Replay equals live | a fake-bridge session recorded and replayed gives the same per-hand counters as the live run |
| Metadata hygiene | no token, no config block, no key, no full Bluetooth address in any file a test writes |
| Recorder cost | appending one record takes below 2 microseconds on average on the CI host, with no allocation |

### Owner-run hardware tests

| Id | Procedure | Pass |
| --- | --- | --- |
| M5-H1 | Record 10 minutes, both hands, batched stream over Wi-Fi from the Pi | per hand **`IMU` rows == sequence span minus sequence gaps** (span = last sequence - first sequence + 1); the final `STATS` equals a recount; `records_dropped` 0 |
| M5-H2 | Same file | per hand the **median tick `dt` is between 5 and 6 ms** (about 4.99 ms was user-reported on an ESP32 bridge; the bar allows for the 5.88 ms the app's simulator assumes) and `received_at_us` never decreases |
| M5-H3 | Same file | size within 5 % of `68 bytes x IMU rows` plus the other record types; about 1.63 MB/min at full rate |
| M5-H4 | Same session | the stream rate and loss during recording are within 1 % of a session without recording (recorder on and off, same position, back to back) |
| M5-H5 | Kill the app during a recording | the file reads to within 250 ms of the kill; no final `STATS`, reported as not cleanly closed |
| M5-H6 | Include one controller power-cycle and one Wi-Fi off/on in a recording | the events are in the file (`controller_disconnected`, `controller_connected`, `transport_switch`), and replay reproduces the live counters |
| M5-H7 | Run the timeline acceptance of [TIMELINE.md](TIMELINE.md) ("On recorded data") on the M5-H1 file | each row passes, or the unclamped slope is outside 200 ppm and `maxDriftPpm` is revised with the measured value |

## M6. DroidDeck output

Goal: the DroidDeck packets carry a real, monotonic sample time and the
output survives send errors.

### Automated

| Test | Where | State | Pass |
| --- | --- | --- | --- |
| Packet layout | `packages/wmr_core/test/droiddeck_xr_sink_test.dart` | exists | passes |
| `sampleTimeNs` comes from the timeline, on `CLOCK_MONOTONIC` | same file | to write | non-zero, strictly increasing per hand, equal to `hostTimeNs` plus the measured clock offset |
| Send does not block the main isolate; an error does not stop the output and the socket is reopened | `packages/wmr_core/test/`, `apps/wmr_companion_app/test/hid/droiddeck_output_test.dart` | to write | a failing fake transport is retried; later packets are sent |
| Angular velocity is the calibrated gyro, not zero | sink test | to write | matches the input record |

### Owner-run hardware tests

| Id | Procedure | Pass |
| --- | --- | --- |
| M6-H1 | DroidDeck receiving from the app, both controllers on the Pi bridge, 5 minutes. Log the received packets on the DroidDeck side | per hand **`sampleTimeNs` is non-zero and strictly monotonic** in every packet; it trails the receive time by less than 100 ms at the median |
| M6-H2 | Stop and restart the DroidDeck receiver during the run | output resumes within 2 s without restarting the app |
| M6-H3 | Buttons, trigger, stick and orientation checked by hand in DroidDeck | each input reaches DroidDeck on the correct hand |
| M6-H4 | Wi-Fi off and on during the run (M4-H2, M4-H3) | DroidDeck input continues across both switches; `sampleTimeNs` stays monotonic |

Until the timeline is implemented, M6-H1 can only check the existing
fallback (the send time), which is monotonic but is not a sample time. That
result must be labelled as such.

## S1-S5. Spec items

These change the wire or the status. For each, the order is fixed: spec text
(on WMR_Bridge PR #238, branch `docs/spec-patches`, not yet merged: `docs/PROTOCOL.md` "Proposals" and `docs/SWITCH.md`), golden
vectors, bridge code, app code. Every row is "to write".

| Id | Item | Automated | Owner-run hardware test |
| --- | --- | --- | --- |
| S1 | Flag bits `TICKS_SYNTHETIC`, `RX_TIME_SYNTHETIC`, `TICK_RESET` | New vector file version with records that set each bit. Parsers on both sides keep the bits. Old app build against a new fake bridge: no behaviour change. `TICK_RESET` starts a timeline epoch on that record. `RX_TIME_SYNTHETIC` records are excluded from offset estimation | Power-cycle a controller on a bridge that implements S1: the first record after the reconnect has `TICK_RESET` in the raw IMU log; no other record has it |
| S2 | `boot_id`, `controller_epoch`, `features` | Status version 2 golden bytes (24 bytes) parsed by both sides; version 1 parsers accept the longer value. WebSocket `hello`/`status` fields. App re-baselines on a `boot_id` change and starts an epoch on a `controller_epoch` change | Restart the daemon during a session: the app shows one bridge restart, no out-of-order burst. Power-cycle a controller: its epoch increments by 1 and the other hand's does not |
| S3 | Echo version 2 | 28-byte golden answers with each validity flag. App falls back to version 1 on a timeout and never sends version 2 without `ECHO_V2`. Pi answer has `TX_TIME_VALID` and `USER_SPACE_CLOCK` | 120 s latency run on the Pi over BLE: every ping answered; `tx_time_us - rx_time_us` distribution recorded |
| S4 | Switch timing contract (secondary) | The worked example of WMR_Bridge `docs/SWITCH.md` (PR #238, branch `docs/spec-patches`, not yet merged) as a firmware test vector. Ticks advance by at least 1 ms per record. App `SwitchBurstTimestamps` leaves supplied ticks unchanged. `TickTimer` reports no discontinuity on a simulated 60 s stream | Needs a Switch controller and the ESP32 firmware; not part of the Pi and WMR scenario |
| S5 | Switch 44-byte blob (secondary) | Firmware packs version, device type and the 42 bytes (spec on WMR_Bridge PR #238, branch `docs/spec-patches`, not yet merged); `SwitchCalibration.parse` accepts the firmware's golden blob. The gyro factor (816 or 936) is settled and identical on both sides | As S4 |

## Regression set for every change in this plan

Run before a change is called done, whatever the milestone:

1. WMR_Bridge (PR #238, branch `docs/spec-patches`, not yet merged): `cd pi && ./run_tests.sh` and
   `python3 -m pytest tests/test_golden_vectors.py -q`.
2. WMR_Bridge: `python3 tests/test_docs_links.py` and
   `python3 tests/test_doc_gatt.py` after a documentation change.
3. App: `dart test` in `packages/wmr_core`, `packages/wmr_ws` and
   `packages/wmr_companion`; `dart format --set-exit-if-changed` as CI does.
4. The two copies of `wmr_golden_v1.json` (app, and WMR_Bridge PR #238, branch `docs/spec-patches`, not yet merged) are byte-identical.

## What this plan does not cover

- Upstream report loss on the Classic links. It is measured (M1-H4) and
  compared with the ESP32 figures, but no milestone here promises a number.
- Absolute latency. The plan checks pauses and ordering; a latency bar needs
  the echo runs of [LATENCY.md](LATENCY.md) repeated on the Pi.
- Security review of the Pi transport (plain `ws://` with a bearer token on
  the LAN; see [STATUS.md](STATUS.md), "Security posture").
- Boards other than the one each result names. A result on a Pi 3B+ says
  nothing about a Pi Zero 2 W or a non-Pi board.
