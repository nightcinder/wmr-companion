# Pose filter tuning against recorded captures (ONY-502)

> **Status: blocked awaiting captures. No constants were chosen.** ONY-501
> requires the grid search to run on recorded anchor traces, not on reasoning.
> No such capture exists yet, so `minCutoff`, `beta` and `dCutoff` are still the
> published defaults. The structural fix and the grid harness are implemented
> and tested; the table below is deliberately unfilled.

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

## The grid harness

`packages/wmr_tracking/tool/pose_filter_tune.dart` replays anchor captures and
evaluates the ONY-501 grid:

- `minCutoff ∈ {1, 2, 4, 8, 16} Hz`
- `beta ∈ {0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2}`
- `dCutoff ∈ {1, 2, 4} Hz`

For each point it reports static jitter `J`, median and peak best-fit lag `L`,
and the fast-flick 90 % rise time. It takes the lowest-`L` point that meets the
jitter bound and writes the full grid plus every capture's before/after metrics
to `build/pose_filter_tune.json`. If no point passes, it exits 1 and says to
escalate to ONY-501; the thresholds are not adjusted.

`PoseCapture.fromRecording` converts an ONY-249 `PoseRecording` into an anchor
trace: one position and one timestamp per new tracking frame for the selected
hand, with repeated viewer samples collapsed. The 60 traces under
`packages/wmr_tracking/test/fixtures/pose_filter_captures/synthetic/` are
**synthetic harness vectors**, not captures: they say `kind: synthetic`,
`app_commit: null`, `firmware_sha: null`. They prove the harness runs; they
must not be used to choose the constants.

## Acceptance

Per runtime, from ONY-501's `filter-spec` rev 1:

- `J <= 0.5 mm` RMS on a 10 s static hold, measured from the filtered
  position's 1 s moving mean.
- median `L <= 20 ms` on medium and fast lateral sweeps, where `L` is the
  best-fit time shift between raw and filtered.
- the whole grid is published, not just the winner.

## Before and after (pending captures)

Every cell stays empty until the hardware runs exist. Fill one row group per
runtime; the tuner prints the numbers in this shape.

| Runtime | Motion | `J` before | `J` after | `L` median before | `L` median after | Peak `L` before | Peak `L` after | `t90` before | `t90` after |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Android XR | still | | | — | — | — | — | — | — |
| Android XR | slow pan | — | — | | | | | — | — |
| Android XR | medium pan | — | — | | | | | — | — |
| Android XR | fast flick | — | — | | | | | | |
| Android XR | occlusion | — | — | | | | | — | — |
| VITURE | still | | | — | — | — | — | — | — |
| VITURE | slow pan | — | — | | | | | — | — |
| VITURE | medium pan | — | — | | | | | — | — |
| VITURE | fast flick | — | — | | | | | | |
| VITURE | occlusion | — | — | | | | | — | — |
| XREAL | still | | | — | — | — | — | — | — |
| XREAL | slow pan | — | — | | | | | — | — |
| XREAL | medium pan | — | — | | | | | — | — |
| XREAL | fast flick | — | — | | | | | | |
| XREAL | occlusion | — | — | | | | | — | — |

## Capture procedure (ONY-249)

Record at least four runs per motion class, each at least 30 s, per runtime:

1. **Still:** controller on a fixed surface, device flat; this is the noise
   floor.
2. **Slow pan:** lateral sweeps around 0.06 m/s.
3. **Medium pan:** lateral sweeps around 0.3 m/s.
4. **Fast flick:** lateral flicks around 1 m/s or faster.
5. **Occlusion:** hand-anchor motion with the hand briefly hidden; the
   recording must contain the dropout.

For every file record the runtime (`androidXr`, `viture`, `xreal`), the app
commit, the firmware short SHA, the anchor rate and the run index in the
`provenance` block. Use the debug screen's pose recorder, pull the JSON, and
convert it with `PoseCapture.fromRecording` or add the conversion to the
recorder export.

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
