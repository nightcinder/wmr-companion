# Bench run sheet: steps 4 and 5, TCP to BLE recovery

This sheet covers step 4 (BLE takeover) and step 5 (TCP recovery) of the Pi
bench. The base checklist is `WMR_Bridge` `docs/runs/sheets/bench.md:10,21-24`.

Citations without a repository name resolve in this repository. Citations that
start with `WMR_Bridge` resolve in the sibling WMR_Bridge repository.

## Marks

| Mark | Meaning |
| --- | --- |
| T0 | The Pi loses `wlan0`. Start of the injected outage. |
| T1 | `wlan0` is up again with an IPv4 address. End of the outage. |
| T2 | The app reads its first record over TCP after the route returns. The table records it from the Pi journal, as a lower bound. |
| Step-4 takeover | First BLE record minus last TCP record. |

Step 4 is measured on the phone. The composite stamps the last TCP record and
the first BLE record (`packages/wmr_companion/lib/src/composite_transport.dart:1472-1474`).
Those two marks bound the takeover.

T2 is the app's `first_tcp_record_us` mark. The app sets it on the first TCP
record after an upgrade dial ends (`packages/wmr_companion/lib/src/link_timeline.dart:116-121`).

T2−T1 and T2−T0 need one clock. T0 and T1 are Pi shell times, and the app mark
is on the phone clock. Record T2 from the first
`client <address>:<port> subscribed to batched` line after T1
(`WMR_Bridge` `pi/wmr_bridge/bridge.py:984`). The bridge logs that line when it
accepts the subscription, before it sends the first record, so the line is a
Pi-clock lower bound for T2. A lower bound can pass a gate that the app mark
would fail. Record `first TCP +` from the Debug row in the same run as the
phone-clock cross-check (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:634`).
If the bound sits inside the gate but `first TCP +` is large, look again before
you pass the run.

The base sheet says to read T2 when the app reports TCP streaming
(`WMR_Bridge` `docs/runs/sheets/bench.md:23`). This sheet reads the journal line
instead, because the two gate intervals subtract Pi-clock marks.

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
| T2 − T1 | at most 5 s | `docs/TEST_PLAN_PI_WMR.md:158` |
| T2 − T0 | at most 15 s | ONY-1508 plan, Option A |

M4-H3 sets the upgrade gate at 5 s (`docs/TEST_PLAN_PI_WMR.md:158`). The
gate is T2 − T1: the first TCP record after the TCP route returns, less
the moment `wlan0` has an address.

## Split the upgrade delay

Two phone-clock intervals show where the time went. Read them from the
bundle's `link_timeline` entry. The Debug row shows `dial` and
`first TCP +` (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:631-634`).
Their sum is the landing attempt.

| Interval | Calculation | Means |
| --- | --- | --- |
| Wait to first attempt | `first_upgrade_dial_start_us − failover_end_us` | BLE active to the first dial attempt |
| Landing attempt | `first_tcp_record_us − upgrade_dial_start_us` | Start of the last attempt to the first TCP record |

`upgrade_dial_attempts` counts every attempt in the episode. The landing
attempt is the last one, so the failed attempts before it number
`upgrade_dial_attempts − 1` when `first_tcp_record_us` is present. Every
attempt moves `upgrade_dial_start_us`, while
`first_upgrade_dial_start_us` keeps the first attempt's start
(`packages/wmr_companion/lib/src/link_timeline.dart:75-82`, `:192-197`).

Never subtract these phone marks from T1. Pair the two intervals with the
journal T2 to explain the gate result.

## Before the run

- Use the composite link. Turn on **BLE fallback** on the Connect screen
  (`apps/wmr_companion_app/lib/ui/connect/connect_screen.dart:1124`). It is on
  by default (`:61`).
- The row appears only for a `CompositeBleTransport` on the real source
  (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:80-83`). It sits
  under **Stream** in the Debug screen (`:217-229`).
- Before the first switch the row reads `Last link switch none yet` (`:636`).
- On the Pi, `wmr-bridge` runs and both controllers stream. Isolate or unplug
  `eth0`, and confirm that `wlan0` is the uplink (`WMR_Bridge`
  `docs/runs/sheets/bench.md:10`). With `eth0` still connected, the outage may
  never start.

## One run

Run this three times. One run takes about 40 s.

**1. Start the journal capture.** Keep it open for the whole run.

```
journalctl -u wmr-bridge -f -o short-precise --utc | tee /tmp/run-1.journal
```

`--utc` matches the shell marks below. `short-precise` adds microseconds to
each line. Both flags are in the `journalctl` manual
(https://www.freedesktop.org/software/systemd/man/latest/journalctl.html).

**2. Record the address and the starting row.**

```
ip -o -4 addr show dev wlan0 up
```

**3. Take the link down.** Record T0 straight after.

```
sudo ip link set wlan0 down
date -u '+%F %T.%3N'
```

**4. Step 4.** Watch the row change to `TCP→BLE`. Read `takeover` and the
parts it is made of: `stall +`, `failover`, `first BLE +`.

**5. Hold the outage for 10 s after T0.**

**6. Bring the link up.** Wait for a running link with an address. Record T1.

```
sudo ip link set wlan0 up
until ip -o -4 addr show dev wlan0 up | grep -qw inet; do sleep 0.1; done
date -u '+%F %T.%3N'
```

The `up` filter lists only running interfaces
(https://man7.org/linux/man-pages/man8/ip-address.8.html). The address alone is
not proof, because the IPv4 address survives the outage.

**7. Step 5.** Watch the row change to `BLE→TCP`. Read `dial` and
`first TCP +`.

**8. Read T2 from the journal.** Find the first
`client <address>:<port> subscribed to batched` line after T1
(`WMR_Bridge` `pi/wmr_bridge/bridge.py:984`). Use its timestamp as the Pi-clock
lower bound for T2. Read the Debug row's `first TCP +` in the same run.

**9. Read `dropped=` from the last status line.** The bridge prints one every
5 s (`WMR_Bridge` `pi/wmr_bridge/__main__.py:943-953`).

**10. Export the bundle.** Tap **Export test bundle** on the Connect screen
(`apps/wmr_companion_app/lib/ui/connect/connect_screen.dart:1189`). The file is
`wmr-ext-<yyyyMMdd>.zip` in the app documents `exports` folder
(`apps/wmr_companion_app/lib/services/test_bundle.dart:426`,
`apps/wmr_companion_app/lib/services/test_bundle_export.dart:85-88`).
The exported `link_timeline` carries the marks that split the upgrade delay.
Read `first_upgrade_dial_start_us`, `upgrade_dial_attempts`,
`upgrade_dial_start_us` and `first_tcp_record_us`.

**11. Start the next run only after the route is back on TCP.**

## Where each number comes from

| Number | Producer | Detail |
| --- | --- | --- |
| T0 | Pi shell | `date -u '+%F %T.%3N'` right after the down command |
| T1 | Pi shell | `date -u '+%F %T.%3N'` right after the `ip` poll |
| T2 | Pi journal | `client <address>:<port> subscribed to batched` line (`WMR_Bridge` `pi/wmr_bridge/bridge.py:984`). Pi-clock lower bound, logged before the first record |
| T2, app copy | Debug row `BLE→TCP` | `first TCP +` is first TCP record minus dial end, both on the phone clock (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:634`). The absolute mark is `first_tcp_record_us` (`packages/wmr_companion/lib/src/link_timeline.dart:84-85`), and an attached export carries it in `link_timeline` (see below) |
| Wait to first attempt | Bundle `link_timeline` | `first_upgrade_dial_start_us − failover_end_us`, both phone marks. BLE activation to the first dial attempt (`:65`, `:78`) |
| Landing attempt | Bundle `link_timeline` | `first_tcp_record_us − upgrade_dial_start_us`, both phone marks. Start of the last attempt to the first TCP record (`:72`, `:85`) |
| Detect | Debug row `stall +` | `stall_detected_us − last_tcp_record_us` (`packages/wmr_companion/lib/src/link_timeline.dart:56`, `:60`) |
| Failover | Debug row `failover` | `failover_end_us − failover_begin_us` (`:64-65`) |
| First BLE | Debug row `first BLE +` | `first_ble_record_us − failover_end_us` (`:68`) |
| Takeover | Debug row `takeover` | `first_ble_record_us − last_tcp_record_us` (`apps/wmr_companion_app/lib/ui/debug/debug_screen.dart:629`) |
| Dropped | Pi journal | `dropped=` in the 5 s status line (`WMR_Bridge` `pi/wmr_bridge/__main__.py:943-953`) |

The row prints the takeover itself, as `takeover`: first BLE record minus
last TCP record, the figure the gate reads, with `stall +`, `failover` and
`first BLE +` as the parts it is made of. A failover that began from a loss
remembered while a switch held the route has no `stall +` of its own; its
takeover is the only computable figure. While the first BLE record or the
last TCP record is missing the row prints `takeover n/a`: write `n/a` in
the Takeover column.

The parts leave out the gap between the stall mark and the failover
begin. Both stamps land in the same event-loop turn
(`packages/wmr_companion/lib/src/composite_transport.dart:929`, `:969`).
The parts are enough to cross-check the takeover unless it lands within a
few milliseconds of 2500 ms.

The stall mark lands after the liveness probe gives up. The defaults are a
500 ms probe interval and a 1000 ms timeout
(`packages/wmr_ws/lib/src/wmr_ws_transport.dart:93-94`). A `stall +` near
1500 ms is the probe, not the failover.

## Fill-in table

| Run | Date (UTC) | Benched SHA | App version | T0 | T1 | T2 (Pi journal) | first TCP + | T2 − T1 | T2 − T0 | dropped | Pass |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | | | | | | | | | | | |
| 2 | | | | | | | | | | | |
| 3 | | | | | | | | | | | |

The two gate intervals use the journal T2, so both are lower bounds. Record
`first TCP +` beside them. It is the phone-clock view of the first record delay.

| Run | stall + | failover | first BLE + | Takeover | At most 2500 ms |
| --- | --- | --- | --- | --- | --- |
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |

A run passes when all three gates hold. A run that fails one gate fails the
step.

The split is diagnostic, not a gate. Record it from the bundle for each run:

| Run | Wait to first attempt | Attempts | Landing attempt |
| --- | --- | --- | --- |
| 1 | | | |
| 2 | | | |
| 3 | | | |

## The bundle's copy of the timeline

`diagnostics.json` carries the marks under `link_timeline`
(`apps/wmr_companion_app/lib/services/test_bundle.dart:605`). The top-level
keys are the marks of the most recent episode. They include
`first_upgrade_dial_start_us` and `upgrade_dial_attempts`
(`packages/wmr_companion/lib/src/link_timeline.dart:98-99`) and
`episode_last_tcp_record_us`, the anchor that episode's own stall froze.
The `episodes` key lists the same marks for the last finished episodes.
A stall a later switch superseded stays readable in the zip.

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
at least zero after the route has moved on. T2 itself stays the journal
line: the episode's `first_tcp_record_us` is the phone-clock
cross-check, information only, never a substitute.
