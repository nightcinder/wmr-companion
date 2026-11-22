# Bench run sheet: steps 4 and 5, TCP to BLE recovery

This sheet covers step 4 (BLE takeover) and step 5 (TCP recovery) of the Pi
bench. The base checklist is `WMR_Bridge` `docs/runs/sheets/bench.md:7,11,23-26`.

Citations without a repository name resolve in this repository. Citations that
start with `WMR_Bridge` resolve in the sibling WMR_Bridge repository.

## Marks

| Mark | Meaning |
| --- | --- |
| T0 | The Pi loses `wlan0`. Start of the injected outage. |
| T1 | `wlan0` is up again with an IPv4 address. End of the outage. |
| T2 | The app reads its first record over TCP after the route returns. The scored value is the Pi-clock upper bound from the USB receipt capture. |
| Landing | First TCP record minus the start of the last dial, both on the phone clock. |
| Step-4 takeover | First BLE record minus last TCP record. |

Step 4 is measured on the phone. The composite stamps the last TCP record and
the first BLE record (`packages/wmr_companion/lib/src/composite_transport.dart:1823-1839`).
Those two marks bound the takeover.

T2 is the app's `first_tcp_record_us` mark. The app sets it on the first TCP
record after an upgrade dial ends
(`packages/wmr_companion/lib/src/link_timeline.dart:94`, `:196-204`).

T2−T1 and T2−T0 need one clock. T0 and T1 are Pi times, and the app mark is on
the phone clock. Do not subtract the app mark from a Pi time. The debug app
logs each receipt under Android tag `WmrBenchReceipt`
(`apps/wmr_companion_app/lib/services/bench_receipt_log.dart:17`). The line
carries `session`, `first_tcp_record_us` and `first_tcp_record_wall_us`
(`:38-40`). The USB capture stamps the line on the Pi right after it reads the
line.

The composite emits the route ID on `tcpReceipts` as soon as
`first_tcp_record_us` is stamped
(`packages/wmr_companion/lib/src/composite_transport.dart:230`, `:713-715`). In
debug builds, the app listens to `tcpReceipts` and writes the line immediately
(`apps/wmr_companion_app/lib/app.dart:34-40`, `:58-66`). USB, buffering, and
scheduling delay can only make the stamp later. That stamp is a conservative
Pi-clock upper bound for T2.

Match the line to the fresh export by `session` and `first_tcp_record_us`. A
missing or ambiguous match rejects the run.

The journal line `client <address>:<port> subscribed to batched` after T1
(`WMR_Bridge` `pi/wmr_bridge/bridge.py:984`) stays a Pi-clock lower bound. The
bridge logs it before it sends the first record. A lower bound that already
exceeds a gate fails the run. It cannot pass the run.

Record `first TCP +` from the Debug row in the same run as the phone-clock
cross-check (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:643`). If
the upper bound sits inside the gate but `first TCP +` is large, look again
before you pass the run.

The step-4 takeover is a duration on the phone alone. `docs/TEST_PLAN_PI_WMR.md:157`
defines it as the time from the last WebSocket record to the first BLE record.

The phone marks use a Stopwatch since app start
(`packages/wmr_core/lib/ble/ble_transport.dart:58-64`). They compare only with
each other (`packages/wmr_companion/lib/src/link_timeline.dart:3-5`). Never
subtract a phone mark from a Pi time.

## Gates

| Check | Gate | Source |
| --- | --- | --- |
| Step-4 takeover | at most 2500 ms | `docs/TEST_PLAN_PI_WMR.md:157` |
| T2 − T1 | at most 5 s | `docs/TEST_PLAN_PI_WMR.md:158`; ONY-1631 rev 3 |
| T2 − T0 | at most 15 s | ONY-1508 plan, Option A; ONY-1631 rev 3 |
| Landing | at most 750 ms | ONY-1606 plan; ONY-1615; ONY-1631 rev 3 |
| BLE landing | required, with at least one attempt | ONY-1631 rev 3 |

M4-H3 sets the upgrade gate at 5 s (`docs/TEST_PLAN_PI_WMR.md:158`). The
gate is T2 − T1: the first TCP record after the TCP route returns, less
the moment `wlan0` has an address.

The landing gate runs from `upgrade_dial_start_us` to `first_tcp_record_us`,
both phone marks (`packages/wmr_companion/lib/src/link_timeline.dart:81-94`).
It includes the delay between the dial end and the first record. ONY-1606's
plan sets the 750 ms bound. ONY-1631 rev 3 defines landing this way and
applies it to the dial that delivered the record.

Every scored run must show a BLE landing and at least one attempt. The
`failover_outcome` of the episode must be `landed`
(`packages/wmr_companion/lib/src/link_timeline.dart:102-107`), and
`upgrade_dial_attempts` must be at least one (`:91`). A run that closes through
`recovery_lane: redial` has no landing and fails, even when its timing bounds
pass (`:115-121`).

## Split the upgrade delay

The split has three parts. They show where the time went. Read them from the
bundle's `link_timeline` entry. The Debug row shows `dial` and
`first TCP +` (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:640-643`).
The first part ends where the attempts start. The second covers the last
dial. The third is the mean time between attempt starts.

| Interval | Calculation | Means |
| --- | --- | --- |
| Wait to first attempt | `first_upgrade_dial_start_us − failover_end_us` | BLE active to the first dial attempt |
| Landing | `first_tcp_record_us − upgrade_dial_start_us` | Start of the last attempt to the first TCP record |
| Mean attempt spacing | `(upgrade_dial_start_us − first_upgrade_dial_start_us) / (upgrade_dial_attempts − 1)` | Mean start-to-start gap between attempts |

`upgrade_dial_attempts` counts every attempt in the episode. The landing uses
the last attempt's start, so the failed attempts before it number
`upgrade_dial_attempts − 1` when `first_tcp_record_us` is present. Every
attempt moves `upgrade_dial_start_us`, while
`first_upgrade_dial_start_us` keeps the first attempt's start
(`packages/wmr_companion/lib/src/link_timeline.dart:84-91`, `:258-273`).

A failed dial re-arms after 100 ms while the 30 s post-failover window is
open (`packages/wmr_companion/lib/src/composite_transport.dart:76-77`,
`:1412`, `:1426-1439`). The probe budget caps one dial at 300 ms (`:78`). The worst
wait from a route return to the next dial is 400 ms. The dial result is the
probe, so no Pi reachability signal is involved (ONY-1631 plan rev 3,
Child 1).

Upgrade and BLE-drop recovery dials put the last-working TCP candidate first
(`packages/wmr_companion/lib/src/composite_transport.dart:746-756`, `:955`,
`:1287`, `:1371`). Each non-last candidate gets up to 250 ms when the
remaining budget exceeds that cap (`:81`, `:781-785`). Otherwise, the
remaining candidates share the remaining budget evenly (`:785-788`). The last
candidate keeps the full remaining budget (`:780-781`).

Mean attempt spacing uses the two dial-start marks and the attempt count
(`packages/wmr_companion/lib/src/link_timeline.dart:81`, `:87`, `:91`). It is
the mean start-to-start gap, so it includes each failed dial's probe. The
400 ms bound applies to that gap. Write `n/a` when the episode made one
attempt.

Never subtract these phone marks from T1. Pair these intervals with the
receipt T2 and the journal lower bound to explain the gate result.

## Before the run

- Use the composite link. Turn on **BLE fallback** on the Connect screen
  (`apps/wmr_companion_app/lib/ui/connect/connect_screen.dart:1124`). It is on
  by default (`:61`).
- The row appears only for a `CompositeBleTransport` on the real source
  (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:80-83`). It sits
  under **Stream** in the Debug screen (`:217-229`).
- Before the first switch the row reads `Last link switch none yet` (`:645`).
- On the Pi 3B+, run on a `btusb` `hci0` adapter with `dtoverlay=disable-bt`
  for Option B (`WMR_Bridge` `docs/runs/sheets/bench.md:7`). Do not use an
  `hci_uart*` or `serial` adapter, because `wmr-bridge` auto-gates serial
  adapters to TCP-only (`WMR_Bridge` `pi/wmr_bridge/__main__.py:801-816`,
  `pi/wmr_bridge/bluez.py:90-148`). Make sure that the `wmr-bridge` log prints
  `BLE GATT: FF10 on ...` (`WMR_Bridge` `pi/wmr_bridge/__main__.py:843-847`).
  Make sure that `wmr-bridge status` prints `powered=yes` (`WMR_Bridge`
  `pi/wmr_bridge/__main__.py:608-610`).
- On the Pi, `wmr-bridge` runs and both controllers stream. Isolate or unplug
  `eth0`, and confirm that `wlan0` is the uplink (`WMR_Bridge`
  `docs/runs/sheets/bench.md:11`). With `eth0` still connected, the outage may
  never start.

## Clock proof and receipt capture

Both gate intervals subtract Pi-clock marks. Start this capture on the Pi
before T0 and keep it open through T2. Save the script to `/tmp` on the Pi,
then run the pipeline under it. On a scored `wlan-cycle 10` run, take T0 and
T1 from the Pi wrapper's `/tmp/failover.log`. The manual marks below use the
same Pi clock.

```bash
cat > /tmp/clock-proof.py <<'PY'
#!/usr/bin/env python3
"""Stamp WmrBenchReceipt lines on the Pi clock and prove clock continuity.

Read logcat lines on stdin. Write one JSON record per line to argv[1].
Exit 0 only when the clock proof passes. Exit 2 rejects the run.
"""
import ctypes
import json
import os
import sys
import time

CLOCK_REALTIME = 0
TFD_CLOEXEC = 0o2000000
TFD_TIMER_ABSTIME = 1
TFD_TIMER_CANCEL_ON_SET = 2
ECANCELED = 125


class Timespec(ctypes.Structure):
    _fields_ = [("sec", ctypes.c_long), ("nsec", ctypes.c_long)]


class Itimerspec(ctypes.Structure):
    _fields_ = [("interval", Timespec), ("value", Timespec)]


def timerfd():
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    fd = libc.timerfd_create(CLOCK_REALTIME, TFD_CLOEXEC)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "timerfd_create")
    # Absolute, one-shot, one hour out: a realtime clock set cancels it.
    spec = Itimerspec(Timespec(0, 0), Timespec(int(time.time()) + 3600, 0))
    if libc.timerfd_settime(
        fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, ctypes.byref(spec), None
    ) != 0:
        raise OSError(ctypes.get_errno(), "timerfd_settime")
    os.set_blocking(fd, False)
    return fd


def continuity(fd):
    try:
        while os.read(fd, 8):
            pass
    except BlockingIOError:
        return "ok"
    except OSError as error:
        if error.errno == ECANCELED:
            return "clock_set"
        raise
    return "ok"


def stamp(fd, boot_id):
    return {
        "realtime_us": time.time_ns() // 1000,
        "boottime_us": time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1000,
        "boot_id": boot_id,
        "continuity": continuity(fd),
    }


def receipt_pair(line):
    fields = dict(part.split("=", 1) for part in line.split() if "=" in part)
    return fields.get("session") or None, fields.get("first_tcp_record_us") or None


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "clock-proof.jsonl"
    simulate = "--simulate-clock-set" in sys.argv
    fd = timerfd()
    with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
        boot_id = handle.read().strip()
    out = open(out_path, "w", encoding="utf-8")

    def write(record):
        out.write(json.dumps(record, sort_keys=True) + "\n")
        out.flush()

    start = stamp(fd, boot_id)
    start["record"] = "start"
    write(start)
    last_realtime = start["realtime_us"]
    last_boottime = start["boottime_us"]
    events = []
    verdict = "ok"
    try:
        for line in sys.stdin:
            stripped = line.strip()
            if not stripped or stripped.startswith("--------- "):
                continue
            if (
                "WmrBenchReceipt" not in stripped
                and "first_tcp_record_us=" not in stripped
                and "session=" not in stripped
            ):
                continue
            event = stamp(fd, boot_id)
            event.update(record="event", line=line.rstrip("\n"))
            if event["realtime_us"] < last_realtime:
                verdict = "unordered"
            if event["boottime_us"] < last_boottime:
                verdict = "unordered"
            if event["continuity"] != "ok":
                verdict = "clock_set"
            last_realtime = event["realtime_us"]
            last_boottime = event["boottime_us"]
            events.append(event)
            write(event)
    except KeyboardInterrupt:
        pass
    status = "clock_set" if simulate else continuity(fd)
    stop = stamp(fd, boot_id)
    stop.update(record="stop", continuity=status)
    write(stop)
    if stop["boot_id"] != boot_id:
        verdict = "rebooted"
    elif status != "ok":
        verdict = status
    elif stop["realtime_us"] < last_realtime:
        verdict = "unordered"
    elif stop["boottime_us"] < last_boottime:
        verdict = "unordered"
    elif verdict == "ok":
        if not events:
            verdict = "no_receipt"
        else:
            pairs = [receipt_pair(event["line"]) for event in events]
            if any(None in pair for pair in pairs):
                verdict = "bad_receipt"
            elif len(pairs) != len(set(pairs)):
                verdict = "ambiguous"
    write({"record": "verdict", "verdict": verdict, "events": len(events)})
    out.close()
    print(verdict)
    return 0 if verdict == "ok" else 2


if __name__ == "__main__":
    sys.exit(main())
PY
```

```
adb -d logcat -v raw -s WmrBenchReceipt:I | \
  python3 /tmp/clock-proof.py /tmp/run-1.clock-proof.jsonl
```

The command writes one JSON record per line to `clock-proof.jsonl`. The
`start`, `event`, and `stop` records carry `realtime_us` and `boottime_us`.
The `verdict` record carries the result. The script arms a realtime timerfd
with `TFD_TIMER_CANCEL_ON_SET` before the first line. A clock set cancels the
timer, and the read then fails with `ECANCELED`.

Accept the run only when the verdict is `ok`. Reject the run for any other
verdict (`clock_set`, `unordered`, `no_receipt`, `bad_receipt`, `ambiguous`,
or `rebooted`). Reject a capture with no `verdict` record, because the
capture stopped early. A missing export, or a receipt that does not match the
export, also rejects the run.

Match the event to the fresh export by `session` and `first_tcp_record_us`.
Take the event's `realtime_us` as the T2 upper bound and round it up to the
microsecond. Round the wrapper's T0 and T1 down at their recorded resolution.
Both values are on the Pi wall clock, so the Pixel/Pi drift does not enter the
subtraction. The phone's `first_tcp_record_wall_us` identifies the receipt. It
does not enter the subtraction.

Test the script once on the Pi before a scored run:

```
printf '%s\n' 'session=selftest first_tcp_record_us=1 first_tcp_record_wall_us=2' | python3 /tmp/clock-proof.py /tmp/proof.jsonl
```

The verdict must be `ok`, and the event record must carry `realtime_us`. Then
run the same line with `--simulate-clock-set`:

```
printf '%s\n' 'session=selftest first_tcp_record_us=1 first_tcp_record_wall_us=2' | python3 /tmp/clock-proof.py /tmp/proof.jsonl --simulate-clock-set
```

The verdict must be `clock_set`, and the exit status must be 2.

## One run

Run this three times. One run takes about 40 s.

**1. Start the clock-proof capture.** Keep it open for the whole run.

```
adb -d logcat -v raw -s WmrBenchReceipt:I | \
  python3 /tmp/clock-proof.py /tmp/run-1.clock-proof.jsonl
```

**2. Start the journal capture.** Keep it open for the whole run.

```
journalctl -u wmr-bridge -f -o short-precise --utc | tee /tmp/run-1.journal
```

`--utc` matches the shell marks below. `short-precise` adds microseconds to
each line. Both flags are in the `journalctl` manual
(https://www.freedesktop.org/software/systemd/man/latest/journalctl.html).

**3. Record the address and the starting row.**

```
ip -o -4 addr show dev wlan0 up
```

**4. Take the link down.** Record T0 straight after.

```
sudo ip link set wlan0 down
date -u '+%F %T.%3N'
```

**5. Step 4.** Watch the row change to `TCP→BLE`. Read `takeover` and the
parts it is made of: `stall +`, `failover`, `first BLE +`.

**6. Hold the outage for 10 s after T0.**

**7. Bring the link up.** Wait for a running link with an address. Record T1.

```
sudo ip link set wlan0 up
until ip -o -4 addr show dev wlan0 up | grep -qw inet; do sleep 0.1; done
date -u '+%F %T.%3N'
```

The `up` filter lists only running interfaces
(https://man7.org/linux/man-pages/man8/ip-address.8.html). The address alone is
not proof, because the IPv4 address survives the outage.

**8. Step 5.** Watch the row change to `BLE→TCP`. Read `dial` and
`first TCP +`.

**9. Read T2 from the USB capture.** Stop the clock-proof capture with `Ctrl-C`
after T2, then read its verdict. Match the `WmrBenchReceipt` event to the
fresh export by `session` and `first_tcp_record_us`. Use the event's
`realtime_us` as the Pi-clock upper bound. Find the first
`client <address>:<port> subscribed to batched` line after T1
(`WMR_Bridge` `pi/wmr_bridge/bridge.py:984`) as the Pi-clock lower bound. Read
the Debug row's `first TCP +` in the same run.

**10. Read `dropped=` from the last status line.** The bridge prints one every
5 s (`WMR_Bridge` `pi/wmr_bridge/__main__.py:988-1003`).

**11. Export the bundle outside the timing window.** Run this step after step 9
stops `clock-proof.py` and captures T2, and after step 10 reads `dropped=`.
Never export during `[T0, stop(clock-proof)]`. Tap **Export test bundle** on
the Connect screen (`apps/wmr_companion_app/lib/ui/connect/connect_screen.dart:1156-1190`).
The app writes `wmr-ext-<yyyyMMdd>.zip` in the app documents `exports` folder
(`apps/wmr_companion_app/lib/services/test_bundle.dart:426`,
`apps/wmr_companion_app/lib/services/test_bundle_export.dart:85-88`), then
opens Android's share sheet (`SharePlus.instance.share(...)`,
`apps/wmr_companion_app/lib/services/test_bundle_export.dart:225-246`). Keep a
copy of each per-run bundle before the next export overwrites
`wmr-ext-<yyyyMMdd>.zip`. Dismiss Android's share sheet with Back before
step 12 and before the next run's T0. The exported `link_timeline` carries the
marks that split the upgrade delay. Read `first_upgrade_dial_start_us`,
`upgrade_dial_attempts`, `upgrade_dial_start_us`, `upgrade_dial_end_us`,
`first_tcp_record_us`, `first_tcp_record_session`, `first_tcp_record_wall_us`,
`failover_outcome`, `failover_reason`, `failover_candidate_count`,
`upgrade_outcome`, `upgrade_candidate_count`, `recovery_lane`, and
`recovery_us`.

**12. Start the next run only after the route is back on TCP.**

## Where each number comes from

| Number | Producer | Detail |
| --- | --- | --- |
| T0 | Pi shell | `date -u '+%F %T.%3N'` right after the down command |
| T1 | Pi shell | `date -u '+%F %T.%3N'` right after the `ip` poll |
| T2 upper bound | Pi USB capture | `realtime_us` on the matching `WmrBenchReceipt` event. Pi-clock upper bound, stamped immediately after the app records the receipt (`apps/wmr_companion_app/lib/services/bench_receipt_log.dart:38-40`, `packages/wmr_companion/lib/src/composite_transport.dart:226,230,713-715`, `apps/wmr_companion_app/lib/app.dart:34-40,58-66`) |
| T2 lower bound | Pi journal | `client <address>:<port> subscribed to batched` line (`WMR_Bridge` `pi/wmr_bridge/bridge.py:984`). Pi-clock lower bound, logged before the first record |
| T2, app copy | Debug row `BLE→TCP` | `first TCP +` is first TCP record minus dial end, both on the phone clock (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:643`). The absolute mark is `first_tcp_record_us` (`packages/wmr_companion/lib/src/link_timeline.dart:94`, `:196-204`), and an attached export carries it in `link_timeline` (see below) |
| Wait to first attempt | Bundle `link_timeline` | `first_upgrade_dial_start_us − failover_end_us`, both phone marks. BLE activation to the first dial attempt (`:74`, `:87`) |
| Landing | Bundle `link_timeline` | `first_tcp_record_us − upgrade_dial_start_us`, both phone marks. Start of the last attempt to the first TCP record (`:81-94`) |
| Detect | Debug row `stall +` | `stall_detected_us − last_tcp_record_us` (`packages/wmr_companion/lib/src/link_timeline.dart:69`, `:65`) |
| Failover | Debug row `failover` | `failover_end_us − failover_begin_us` (`:73-74`) |
| First BLE | Debug row `first BLE +` | `first_ble_record_us − failover_end_us` (`:77`) |
| Takeover | Debug row `takeover` | `first_ble_record_us − last_tcp_record_us` (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:638`) |
| Dropped | Pi journal | `dropped=` in the 5 s status line (`WMR_Bridge` `pi/wmr_bridge/__main__.py:988-1003`) |

The row prints the takeover itself, as `takeover`: first BLE record minus
last TCP record, the figure the gate reads, with `stall +`, `failover` and
`first BLE +` as the parts it is made of. A failover that began from a loss
remembered while a switch held the route has no `stall +` of its own; its
takeover is the only computable figure. While the first BLE record or the
last TCP record is missing the row prints `takeover n/a`: write `n/a` in
the Takeover column.

The parts leave out the gap between the stall mark and the failover
begin. Both stamps land in the same event-loop turn
(`packages/wmr_companion/lib/src/composite_transport.dart:1138`, `:1181`).
The parts are enough to cross-check the takeover unless it lands within a
few milliseconds of 2500 ms.

The stall mark lands after the liveness probe gives up. The defaults are a
500 ms probe interval and a 1000 ms timeout
(`packages/wmr_ws/lib/src/wmr_ws_transport.dart:85-86`). A `stall +` near
1500 ms is the probe, not the failover.

## Fill-in table

| Run | Date (UTC) | Benched SHA | App version | T0 | T1 | T2 upper (Pi USB) | T2 lower (Pi journal) | T2 − T1 | T2 − T0 | Pass |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | | | | | | | | | | |
| 2 | | | | | | | | | | |
| 3 | | | | | | | | | | |

The gate intervals use the upper bound. The lower bound is the failure check:
if it already exceeds a gate, the run fails. Record `first TCP +` beside them.
It is the phone-clock view of the first record delay.

| Run | stall + | failover | first BLE + | Takeover | dropped | At most 2500 ms |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |

A run passes when all four gates hold and the episode shows a BLE landing with
at least one attempt. A run that fails one gate fails the step.

The split is diagnostic, except the Landing column, which is the gate. Record
it from the bundle for each run:

| Run | Episode JSON path | `failover_outcome` / `failover_reason` | `recovery_lane` | `first_upgrade_dial_start_us` | `upgrade_dial_start_us` | Wait to first attempt | Attempts | `first_tcp_record_us` | Landing | Mean spacing |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | | | | | | | | | | |
| 2 | | | | | | | | | | |
| 3 | | | | | | | | | | |

The Landing column is the gate: at most 750 ms. Write `unavailable` when the
episode has no `first_tcp_record_us`.

Every scored run gets a row in all three tables. When no landing occurs, add a
failure row. Write the episode JSON path, and write `unavailable` in Landing.
Do not leave the row out. A row with `failover_outcome: lost` and
`recovery_lane: redial` is a failure, even when its timing rows pass.

The two mark columns are the raw values. The Wait, Landing and Mean spacing
columns use those marks and the calculations above.

## The bundle's copy of the timeline

`diagnostics.json` carries the marks under `link_timeline`
(`apps/wmr_companion_app/lib/services/test_bundle.dart:605`). The top-level
keys are the marks of the most recent episode. They include
`first_upgrade_dial_start_us` and `upgrade_dial_attempts`
(`packages/wmr_companion/lib/src/link_timeline.dart:134-135`) and
`episode_last_tcp_record_us`, the anchor that episode's own stall froze.
The `episodes` key lists the same marks for the last finished episodes.
A stall a later switch superseded stays readable in the zip.

Do not rely on a single export after Run 3. `LinkTimelineRecorder.episodeHistoryCapacity`
retains only 3 finished episodes (`packages/wmr_companion/lib/src/link_timeline.dart:158`),
so a preflight plus 3 runs drops the oldest episode from `episodes`.

The same entry carries how the episode ended
(`packages/wmr_companion/lib/src/link_timeline.dart:102-121`, `:126-146`):

| Key | Values | Meaning |
| --- | --- | --- |
| `failover_outcome` | `landed`, `lost` | How the failover to BLE ended. |
| `failover_reason` | `no_candidate`, `connect_threw`, `activation_threw` | Why the last BLE candidate failed, when the outcome is `lost`. |
| `failover_candidate_count` | integer | BLE candidates the failover tried. |
| `upgrade_outcome` | `landed`, `no_candidate`, `dial_skipped`, `connect_threw`, `activation_threw`, `route_moved` | How the latest dial ended. |
| `upgrade_candidate_count` | integer | TCP candidates in that dial. |
| `first_tcp_record_session` | string | TCP session that delivered the first record. |
| `first_tcp_record_wall_us` | integer | Phone wall clock at that record. |
| `recovery_lane` | `redial` | Lane that closed a failover with no landing. |
| `recovery_us` | integer | When that recovery happened. |

The failover acquires a candidate before it declares loss
(`packages/wmr_companion/lib/src/composite_transport.dart:1200-1216`). It
skips a refused candidate and tries the next one (`:1220-1237`).

Both dial sites write the same fields: the upgrade probe
(`packages/wmr_companion/lib/src/composite_transport.dart:1355-1413`) and the
BLE-drop recovery (`:1272-1305`). A dial counts once.

A recovery is not a landing. When the app redial delivers TCP after a failover
that never landed, the episode records `recovery_lane: redial` and
`recovery_us`. It leaves the attempt count and dial marks unchanged
(`packages/wmr_companion/lib/src/link_timeline.dart:115-121`,
`packages/wmr_companion/lib/src/composite_transport.dart:409-413`).

The export builder passes the live transport's marks into the bundle
(`apps/wmr_companion_app/lib/services/test_bundle_export.dart`), so the
`first TCP +` row and the failover rows are reproducible from the attached
zip, not only from the Debug screen.

Read an episode's figures from its own anchor, never from the top-level
`last_tcp_record_us`: each episode froze its anchor at the record that
preceded its stall, while the top-level mark keeps tracking the newest
record the route delivered, which a later upgrade moves past it.

The run's own episode is the one the top-level marks describe:

* detect = `stall_detected_us − episode_last_tcp_record_us`
* takeover = `first_ble_record_us − episode_last_tcp_record_us`, `n/a`
  when either mark is absent
* T2, app copy = `first_tcp_record_us`

An episode a later stall superseded reads the same way from its
`episodes[i]` entry, whose `last_tcp_record_us` is its own frozen anchor:

* detect = `episodes[i].stall_detected_us − episodes[i].last_tcp_record_us`
* takeover = `episodes[i].first_ble_record_us − episodes[i].last_tcp_record_us`,
  `n/a` when either mark is absent
* T2, app copy = `episodes[i].first_tcp_record_us`

The takeover this gives is the figure the row printed live, and it stays
at least zero after the route has moved on. T2 itself stays the USB receipt
upper bound: the episode's `first_tcp_record_us` is the phone-clock
cross-check, information only, never a substitute.
