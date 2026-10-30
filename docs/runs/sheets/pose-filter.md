# Pose filter tuning against recorded captures (ONY-502)

> **Status: blocked awaiting captures. No constants were chosen.** ONY-501
> requires the grid search to run on recorded anchor traces, not on reasoning.
> No such capture exists yet, so `minCutoff`, `beta` and `dCutoff` are still the
> published defaults. The structural fix and the 4,264-point harness are
> implemented and tested; the tables below are deliberately unfilled.
>
> Normative source: ONY-501's `filter-spec` **revision 4**. Where this sheet and
> that document disagree, the document wins. Revision 1's grid, speeds and
> acceptance text are superseded.

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

## Before and after (pending captures)

Every cell stays empty until the hardware runs exist. Fill one row group per
runtime; the tuner writes the numbers in this shape.

| Runtime | Segment | `J` before | `J` after | `J_D` before | `J_D` after | `L` median before | `L` median after | Peak `L` before | Peak `L` after | `t90` before | `t90` after |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Android XR | still | | | — | — | — | — | — | — | — | — |
| Android XR | held, drifting | — | — | | | — | — | — | — | — | — |
| Android XR | slow pan | — | — | — | — | | | | | — | — |
| Android XR | medium pan | — | — | — | — | | | | | — | — |
| Android XR | fast flick | — | — | — | — | | | | | | |
| Android XR | occlusion | — | — | — | — | | | | | — | — |
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
follows the path and duration; analysis bins samples by the speed measured from
the reference trajectory and scores only samples within ±25 % of nominal.

| Segment | Sheet name | Nominal speed | How to perform | Duration | Scores |
|---|---|---|---|---|---|
| S | still | 0 | Controller rested in the hand, arm braced | 10 s | J |
| D | held, drifting | 10-50 cm/s | Hold as if aiming; let it wander slowly | 10 s | J_D |
| slow | slow pan | 10 cm/s | 30 cm sideways in 3 s, back and forth | 3 x 6 s | L <= 160 ms |
| M | medium pan | 50 cm/s | 50 cm sideways in 1 s, back and forth | 10 s | L <= 20 ms |
| F | fast flick | 150 cm/s | 45 cm flick in 0.3 s, pause, return | 10 reps | L <= 20 ms |

Record at least four runs per motion class per runtime, each at least 30 s:
repeat the segment path until the run is long enough. Record **each hand**
separately (`TrackedHand.left` and `TrackedHand.right`). Include an occlusion
run (hand-anchor motion with the hand briefly hidden) for diagnostics; rev 4 has
no bar for that class.

For every file record the runtime (`androidXr`, `viture`, `xreal`), the app
commit, the firmware short SHA, the anchor rate and the run index in the
`provenance` block. The guided bench below does this automatically; a
debug-screen recording made by hand needs the same fields added before it can
count as corpus data.

### The guided bench writes the section 8 corpus

The guided bench (`apps/wmr_companion_app/lib/ui/bench/`) now emits this corpus
directly. It is no longer the old still/slow-only wizard described in earlier
revisions.

1. Attach a hand-tracking runtime on the Debug screen, then open **Guided bench
   run** from Connect.
2. Choose **6DoF only** (no bridge) or **Combined**. The pose step records four
   runs of each of the five scored motion classes for each hand, in this order:
   LEFT still x4, LEFT drifting x4, LEFT slow x4, LEFT medium x4, LEFT fast x4,
   then one LEFT occlusion diagnostic; then the same corpus and diagnostic for
   RIGHT. That is **40 corpus files plus 2 diagnostic files**.
3. Each run repeats the section 8 path until it is at least 30 s: still 30 s,
   held drifting 30 s, slow pan 36 s, medium pan 30 s, fast flick 40 s. The
   occlusion run is 30 s and diagnostic only.
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
6. Finish the wizard and export the test bundle. Zip names and the manifest
   table use `pose_capture_<runtime>_<hand>_<segment>.json` for run 1 and
   `..._runN.json` for runs 2-4, and the manifest lists each run's anchor rate.

To tune, extract `pose_capture_*.json` from the bundle and convert each
recording into a capture before pointing the tuner at the directory:

```dart
final recording = PoseRecording.decode(file.readAsStringSync());
final capture = PoseCapture.fromRecording(
  recording,
  runtime: TrackingVendor.viture,
  motion: PoseMotion.still,
  run: 2,
  hand: TrackedHand.left,
);
```

`motion` and `run` come from the file's provenance block. Controller-only
recordings still do not close the gap: with no runtime anchor the fuser falls
back to the head-relative offset or orientation only
(`SixDofFuser.update`), and those paths are never filtered, so they say nothing
about One Euro. A capture needs a runtime that tracks controllers or hands
(Android XR, VITURE or XREAL) attached while the bench records.
`provenance` block. Use the debug screen's pose recorder, pull the JSON, and
convert it with `PoseCapture.fromRecording` or add the conversion to the
recorder export.

### Why the ONY-491 guided bench is not enough

The tuner replays a `PoseRecording`: per viewer tick, the fused controller pose
plus the `TrackingFrame` that positioned it. It only needs the position and
timestamp of each new **anchor** sample, where the anchor is a runtime-tracked
controller pose or a hand palm/grip anchor from the XR runtime.

The guided bench (`apps/wmr_companion_app/lib/ui/bench/`) records 60 s of the
FF11 raw controller stream, a still hold and a slow move per hand, and exports
a test bundle. It has no pose-recorder step, so it writes no `TrackingFrame`s,
and it has no held-drift, medium, fast or occlusion class. Its files cannot feed
the tuner.

Controller-only recordings do not close the gap either: with no runtime anchor
the fuser falls back to the head-relative offset or orientation only
(`SixDofFuser.update`), and those paths are never filtered, so they say nothing
about One Euro. A capture needs a runtime that tracks controllers or hands
(Android XR, VITURE or XREAL) attached while the debug screen records.

## Reproduce

From `packages/wmr_tracking`:

```bash
# harness smoke test on the synthetic vectors (not a tuning result)
dart run tool/pose_filter_tune.dart --markdown build/pose-filter-grid.md

# hardware captures, once recorded
dart run tool/pose_filter_tune.dart \
  --captures path/to/hardware-captures \
  --markdown ../../docs/runs/sheets/pose-filter-grid.md

dart test test/pose_filter_tuning_test.dart test/filter_test.dart
```

After the hardware run, fill the table, copy the chosen constants into
`PoseFilterConfig` and `SixDofFuser` defaults, and add the per-runtime map then.
Until then the defaults stay at the published values.
