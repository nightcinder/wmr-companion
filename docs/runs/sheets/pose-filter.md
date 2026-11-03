# Pose filter tuning against recorded captures (ONY-502)

> **Status: blocked awaiting captures. No constants were chosen.** A complete
> 6-run Android XR corpus was recorded on 2026-11-03 (app 0.3.15, commit
> `591ac18`, no bridge). ONY-501's addendum scores `J` on the last 10 s of S
> with the first 2 s and samples above 2 cm/s dropped, and `J_D` only on the
> 10-50 cm/s D band. The full 4,264-point grid still has **no passing point**:
> `J = 1.514 mm` against 0.5 mm and `J_D = 7.576 mm` against 0.75 mm. The S run
> was hand-held, not braced, and the D run's median speed was 2.9 cm/s, so only
> 43 samples fell in band. A braced S and an in-band D are needed before the
> bars can be judged. Lag passes with margin. Bars and grid are unchanged.
>
> Normative source: ONY-501's `filter-spec` **revision 4**, including its note on
> the 6-run default. Where this sheet and that document disagree, the document
> wins. Revision 1's grid, speeds and acceptance text are superseded.

## What landed

ONY-501 decided to keep the One Euro structure and change the constants. The
structural half is independent of the tuning and is in
`packages/wmr_tracking/lib/src/fusion.dart`:

- the filter gets the anchor sample's own `fusionTimeNs`, not the display tick;
- it is called once per new anchor sample and the filtered value is held
  between samples;
- `minDt` follows the anchor rate (about 11 ms at 90 Hz) instead of the 240 Hz
  IMU, and `maxDt` stays 100 ms;
- a source transition, a gap over 100 ms, a source restart or
  `SixDofFuser.reset()` still resets the filter.

`SixDofFusionConfig.poseFilter` and `PoseFilterConfig` let the harness or a
caller supply a tuned config without another fuser change.

`PoseCapture.fromRecording` now takes the **raw anchor joint position**
(`anchor.pose.translation`) and the tracking frame's own timestamp. It does not
apply a grip offset. Per `filter-spec` sections 3 and 4 the filter sees the
joint, and `R_imu * offset` is applied after filtering; the offset is
calibrated per hand, per joint, per runtime.

## The grid harness

`packages/wmr_tracking/tool/pose_filter_tune.dart` replays anchor captures and
evaluates the whole `filter-spec` rev 4 section 7 grid:

| Constant | Min | Max | Step | Points |
|---|---|---|---|---|
| `minCutoff` | 1.0 Hz | 4.0 Hz | 0.25 Hz | 13 |
| `beta` | 0.00 | 0.40 Hz per cm/s | 0.01 | 41 |
| `dCutoff` | 0.5 Hz | 4.0 Hz | 0.5 Hz | 8 |

That is **4,264 points per runtime**, all evaluated by capture replay. There is
no early stop and no coarse-to-fine pruning. `minDt` is not searched; it follows
the anchor rate per section 5.

`beta` is in hertz per centimetre per second. `OneEuroFilter` scales metre
inputs to centimetres internally, so these grid values are passed to
`PoseFilterConfig.beta` unchanged. An implementation that estimates speed in
metres per second without that scaling must multiply a rev 4 beta by 100. The
old paper betas (0.02-0.05) are in different units and are not grid bounds.

For each point the harness reports static jitter `J`, drift jitter `J_D`, median
best-fit lag `L` on slow, medium and fast sweeps, and the fast-flick 90 % rise
time. It selects the passing point with the **lowest `J_D`**, breaking ties by
the lowest median `L` on medium.

**Edge rule.** If the selected point, or the only passing region, touches a
bar-limiting boundary (`beta = 0.40`, `minCutoff = 1.0` or `4.0`,
`dCutoff = 0.5` or `4.0`), the result is inconclusive: not a pass and not
grounds to escalate. The harness extends that axis by 50 % at the same step,
reruns the whole grid and writes both runs. If the extended run still selects a
boundary point, it exits 3 and says to take both grids to ONY-501.

## Result: Android XR, 2026-11-03

Source: `wmr-aura-0.3.15-test-20261103.zip` from the external tester, Android XR
on a Google Aura (Android 14 / API 34), app 0.3.15 (versionCode 2020) at commit
`591ac18`, no bridge attached so `firmware_sha` is null. Six runs, one per
class, hands alternating, 143 Hz and 26 joints. The prepared corpus is
committed under
`packages/wmr_tracking/test/fixtures/pose_filter_captures/hardware/androidXr-20261103/`
and passes `pose_capture_prepare.dart` coverage (6 of 6 cells, exit 0).

The full 4,264-point grid was replayed twice. Under rev 4's original
full-window score no point passes (`J = 7.644 mm`, `J_D = 1.703 mm`). Under
ONY-501's addendum no point passes either: `J = 1.514 mm` and
`J_D = 7.576 mm`. `J` ranges only 1.514-1.525 mm across the grid and `J_D`
7.562-7.594 mm, so the filter is not the limiting factor. The tuner chose no
constant and exited 1. The addendum grid is in
[pose-filter-grid-androidXr-20261103.md](pose-filter-grid-androidXr-20261103.md).

Lag is not the problem: median `L` is 10 ms on the slow sweep, 1 ms on medium
and 7 ms on fast, all inside their bars. The still trace moves 41 x 66 x 30 mm
peak to peak over 15 s, with a 43.7 mm settle in the first second; the last
10 s still wander about 1.5 mm RMS. That is the hand-held palm anchor, not a
braced source-noise hold. The drifting trace's median speed is 2.9 cm/s, so
only 43 of 2138 samples fall in segment D's 10-50 cm/s band; the gated `J_D`
is therefore not representative of D.

## ONY-501 addendum (2026-11-03)

The design owner's decision after the first full-window failure:

1. Score `J` only on S's last 10 s. Drop the first 2 s settle and any sample
   whose measured speed is above 2 cm/s. Speed is a centred 0.5 s difference
   of the raw anchor position.
2. Capture S braced: forearm on a table and hand relaxed, so the run measures
   source sigma, not tremor. D stays hand-held, but score `J_D` only on samples
   at 10-50 cm/s.
3. Rescore the existing corpus first; if braced S still exceeds 0.5 mm with
   sigma well above 1 mm, escalate again with the measured sigma.
4. The bars and the section 7 grid stay as they are.

The EKF or fixed-lag branch reopens only if a braced, gated capture fails and
the grid spread is wider than 0.1 mm. This corpus is not that test: S was
hand-held and D was below its speed band. The next capture must fix both.

## Acceptance

Per runtime, from ONY-501's `filter-spec` rev 4 sections 1 and 8:

| Metric | Bar | Applies to |
|---|---|---|
| Jitter `J` (RMS from 1 s moving mean) | <= 0.5 mm | segment S, every runtime |
| Jitter `J_D` (residual from 1 s quadratic) | <= 0.75 mm | segment D, every runtime |
| Median lag `L` | <= 20 ms | medium and fast sweeps |
| Median lag `L` | <= 160 ms | slow sweeps, regression check only |

The whole grid is published, not just the winner. The synthetic vectors under
`packages/wmr_tracking/test/fixtures/pose_filter_captures/synthetic/` are
harness vectors, not captures: they say `kind: synthetic`, `app_commit: null`,
`firmware_sha: null`, and must not be used to choose constants.

## Before and after (Android XR, 2026-11-03)

No tuned point exists, so the `after` column repeats the published defaults
(`minCutoff = 1 Hz`, `beta = 0.02`, `dCutoff = 1 Hz`). `before` is the pre-ONY-502
paper default (`minDt = 4.167 ms`). The still and drifting rows use the
addendum gates: 1425 still samples and 43 drifting samples were scored. The
table is evidence of the failure, not a tuning result.

| Runtime | Segment | `J` before | `J` after | `J_D` before | `J_D` after | `L` median before | `L` median after | Peak `L` before | Peak `L` after | `t90` before | `t90` after |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Android XR | still | 1.514 | 1.514 | — | — | — | — | — | — | — | — |
| Android XR | held, drifting | — | — | 7.576 | 7.576 | — | — | — | — | — | — |
| Android XR | slow pan | — | — | — | — | 10 | 10 | 10 | 10 | — | — |
| Android XR | medium pan | — | — | — | — | 1 | 1 | 7 | 7 | — | — |
| Android XR | fast flick | — | — | — | — | 7 | 7 | 9 | 9 | 91.6 | 91.6 |
| Android XR | occlusion | — | — | — | — | 1 | 1 | 8 | 8 | — | — |
| VITURE | still | | | — | — | — | — | — | — | — | — |
| VITURE | held, drifting | — | — | | | — | — | — | — | — | — |
| VITURE | slow pan | — | — | — | — | | | | | — | — |
| VITURE | medium pan | — | — | — | — | | | | | — | — |
| VITURE | fast flick | — | — | — | — | | | | | | |
| VITURE | occlusion | — | — | — | — | | | | | — | — |
| XREAL | still | | | — | — | — | — | — | — | — | — |
| XREAL | held, drifting | — | — | | | — | — | — | — | — | — |
| XREAL | slow pan | — | — | — | — | | | | | — | — |
| XREAL | medium pan | — | — | — | — | | | | | — | — |
| XREAL | fast flick | — | — | — | — | | | | | | |
| XREAL | occlusion | — | — | — | — | | | | | — | — |

## Capture protocol (ONY-249)

`filter-spec` rev 4 section 8 maps the segment names to speeds. The operator
follows the path and duration. Analysis bins samples by the speed measured from
the reference trajectory. It scores only samples within ±25 % of nominal.

ONY-869 makes the guided bench record the 6-run protocol. Builds before that
change still use the section 8 schedule below. One run covers each scored
motion class. One diagnostic occlusion run follows. A run lasts one segment
cycle, between 15 s and 20 s. The capture is 98 s of recording, about 1.5 min.
Hands alternate so both hands appear in the bundle.

| # | Hand | Segment | Sheet name | Nominal speed | How to perform | Duration | Scores |
|---|---|---|---|---|---|---|---|
| 1 | LEFT | S | still | 0 | Rest the hand with the forearm braced on a table; hand relaxed | 15 s | J |
| 2 | RIGHT | D | held, drifting | 10-50 cm/s | Hold as if aiming; let the hand wander at 10-50 cm/s, not a slow drift | 15 s | J_D |
| 3 | LEFT | slow | slow pan | 10 cm/s | Move the hand 30 cm sideways in 3 s, back and forth; keep the body still | 18 s | L <= 160 ms |
| 4 | RIGHT | M | medium pan | 50 cm/s | Move the hand 50 cm sideways in 1 s, back and forth; keep the body still | 15 s | L <= 20 ms |
| 5 | LEFT | F | fast flick | 150 cm/s | Flick the hand 45 cm in 0.3 s, pause, return; keep the body still | 20 s | L <= 20 ms |
| 6 | RIGHT | occ | occlusion | n/a | Aim, then hide the hand for a second or two | 15 s | diagnostic |

The occlusion run has no acceptance bar. It records reacquisition gaps for
diagnostics.

The tuner pools both hands per runtime and motion. The 6-run protocol therefore
covers every scored class without a replicate on each hand. Use it for the
default hardware capture.

### The section 8 lab schedule

Section 8 still asks for four runs per scored class per hand, each at least
30 s. That is 42 runs, about 23 min of recording. Use it only for a lab capture
that needs per-hand replicates, and only with a tester who is not fatigued.

`pose_capture_prepare.dart --full` checks that corpus. Without the flag the tool
checks the 6-run corpus. ONY-869 adds the flag.

### Provenance

For every file record the runtime (`androidXr`, `viture`, `xreal`), the app
commit, the firmware short SHA, the anchor rate and the run index in the
`provenance` block. The guided bench does this automatically. A debug-screen
recording made by hand needs the same fields before it can count as corpus
data.

### The guided bench writes the 6-run corpus

The guided bench (`apps/wmr_companion_app/lib/ui/bench/`) emits this corpus
directly.

1. Attach a hand-tracking runtime on the Debug screen. Open **Guided bench
   run** from Connect.
2. Choose **6DoF only** (no bridge) or **Combined**. The pose step records six
   runs in the order above: LEFT still, RIGHT drifting, LEFT slow pan, RIGHT
   medium pan, LEFT fast flick, RIGHT occlusion.
3. Each run lasts one cycle: still 15 s, drifting 15 s, slow pan 18 s, medium
   pan 15 s, fast flick 20 s, occlusion 15 s.
4. Recordings are sampled once per new anchor frame, not per 30 Hz viewer tick.
   Each `PoseRecording` carries a `provenance` block with `runtime`,
   `app_commit`, `firmware_sha`, `anchor_rate_hz`, `run_index`, `hand`,
   `motion` and `seconds`. Occlusion files also carry
   `diagnostics.occlusion_gaps`, `diagnostics.occluded_samples` and
   `diagnostics.max_occlusion_ms`.
5. Progress is saved after every run in `bench_pose_progress.json` (runtime,
   app commit and plan signature). If the app is interrupted, re-entering the
   pose step skips every run whose file is still on disk. A completed corpus
   starts fresh on the next run.
6. Finish the wizard and export the test bundle. A 6-run file is named
   `pose_capture_<runtime>_<hand>_<segment>.json`. Runs 2-4 of a lab corpus add
   `_runN`. The manifest lists each run's anchor rate.

### One command from bundle to tuning run

`packages/wmr_tracking/tool/pose_capture_prepare.dart` converts the recordings
and checks corpus coverage. From `packages/wmr_tracking`:

```bash
# 1. convert the tester bundle into tuner captures
dart run tool/pose_capture_prepare.dart --bundle wmr-ext-20261030.zip

# 2. tune each runtime on the converted corpus
dart run tool/pose_filter_tune.dart \
  --captures build/pose_corpus/viture \
  --markdown build/pose_corpus/viture-grid.md
```

For a directory of `PoseRecording` JSON (for example the phone's documents
folder) pass `--captures path/to/recordings` instead of `--bundle`; `--out`
changes the default `build/pose_corpus`. A debug-screen recording
(`pose-<timestamp>.json`) has no provenance and cannot be placed in a cell, so
the tool warns and skips it instead of failing the run. The tool reads the
runtime, hand, segment and run from the bundle's `diagnostics.json`, then the
recording's `provenance` block, then the file name
(`pose_capture_<runtime>_<hand>_<segment>[_runN].json`), converts each file with
`PoseCapture.fromRecording`, and writes
`<runtime>/<hand>/<motion>/run<N>.json` plus `coverage.md`. The default matrix
covers S, D, slow, M, F and occlusion per runtime, with both hands pooled.
`--full` prints one row per runtime and hand. ONY-869 sets the 14 s floor, the
pooled matrix and the `--full` flag.

It refuses an incomplete corpus with exit 1 and names every missing cell, for
example `viture/mediumPan: 0 of 1 runs`, and writes nothing in that case. A run
shorter than 14 s also counts as missing and is named
(`viture/mediumPan: run 1 is 12.0 s, needs 14 s`). The check uses the sample
span and allows one second of truncation. The bench stops on a wall-clock timer
and stamps each sample when the frame arrives. The occlusion diagnostic has no
duration bar, so a short occlusion recording still counts. A complete default
corpus is one run of each scored class per runtime across both hands, plus one
occlusion run. With `--full` it is four runs of each scored class per hand and
one occlusion run per hand.

Controller-only
recordings still do not close the gap: with no runtime anchor the fuser falls
back to the head-relative offset or orientation only
(`SixDofFuser.update`), and those paths are never filtered, so they say nothing
about One Euro. A capture needs a runtime that tracks controllers or hands
(Android XR, VITURE or XREAL) attached while the bench records.

## Reproduce

From `packages/wmr_tracking`:

```bash
# harness smoke test on the synthetic vectors (not a tuning result)
dart run tool/pose_filter_tune.dart --markdown build/pose-filter-grid.md

# hardware captures: tester bundle -> corpus -> grid
dart run tool/pose_capture_prepare.dart --bundle path/to/wmr-ext.zip
dart run tool/pose_filter_tune.dart \
  --captures build/pose_corpus/viture \
  --markdown ../../docs/runs/sheets/pose-filter-grid.md

dart test test/pose_filter_tuning_test.dart test/filter_test.dart \
  test/pose_capture_prepare_test.dart
```

After the hardware run, fill the table, copy the chosen constants into
`PoseFilterConfig` and `SixDofFuser` defaults, and add the per-runtime map then.
Until then the defaults stay at the published values.
