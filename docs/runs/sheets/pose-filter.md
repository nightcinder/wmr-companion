# Pose filter tuning against recorded captures 
Status: **blocked awaiting a scorable capture. No constants chosen.**

Normative source:  `filter-spec` rev 4, including its note on the 6-run default. Where this sheet and that document disagree, the document wins. Revision 1's grid, speeds and acceptance text are superseded.

Two complete 6-run Android XR corpora have been replayed. Neither full 4,264-point grid has a passing point, so the published defaults stay. Lag passes with margin. The next capture needs the section 8 prompts: forearm resting on a table, and D moving at 10-50 cm/s.
## What landed
`packages/wmr_tracking/lib/src/fusion.dart` keeps the One Euro structure:

- the filter uses the anchor sample's own `fusionTimeNs`, not the display tick;
- it runs once per new anchor sample and holds the value between samples;
- `minDt` follows the anchor rate (about 11 ms at 90 Hz), `maxDt` stays 100 ms;
- a source transition, a gap over 100 ms, a source restart or `SixDofFuser.reset()` resets it.

`SixDofFusionConfig.poseFilter` and `PoseFilterConfig` accept a tuned config. `PoseCapture.fromRecording` takes the raw anchor joint position (`anchor.pose.translation`) and the tracking timestamp; `R_imu * offset` is applied after filtering.

## The grid harness
`packages/wmr_tracking/tool/pose_filter_tune.dart` replays anchor captures and evaluates the whole rev 4 section 7 grid:

| Constant | Min | Max | Step | Points |
|---|---|---|---|---|
| `minCutoff` | 1.0 Hz | 4.0 Hz | 0.25 Hz | 13 |
| `beta` | 0.00 | 0.40 Hz per cm/s | 0.01 | 41 |
| `dCutoff` | 0.5 Hz | 4.0 Hz | 0.5 Hz | 8 |

That is **4,264 points per runtime**, all replayed, with no early stop and no pruning. `minDt` is not searched.

`beta` is in hertz per centimetre per second. `OneEuroFilter` scales metres to centimetres internally, so these values pass to `PoseFilterConfig.beta` unchanged. A metre-per-second implementation must multiply a rev 4 beta by 100; the old paper betas (0.02-0.05) are not grid bounds.

Per point the harness reports static jitter `J`, drift jitter `J_D`, median best-fit lag `L` on slow/medium/fast sweeps, and fast-flick 90% rise time. It selects the passing point with the lowest `J_D`, then the lowest medium `L`.

**Edge rule.** If the selected point or the only passing region touches a bar-limited boundary (`beta = 0.40`, `minCutoff = 1.0` or `4.0`, `dCutoff = 0.5` or `4.0`), the result is inconclusive. The harness extends that axis by 50% at the same step, reruns, and writes both. If the extended run still selects a boundary point, it exits 3 and says to take both grids.

## Results
| Corpus | App | Best `J` (mm) | `J_D` (mm) | `L` slow / medium / fast (ms) | Points that pass |
|---|---|---|---|---|---|
| Android XR 2026-11-03 | 0.3.15 `591ac18` | 1.514 (range 1.514-1.525) | 7.576 (range 7.562-7.594) | 10 / 1 / 7 | 0 of 4,264 |
| Android XR 2026-11-05 | 0.3.16 `903f03f` | 1.009 (range 1.009-1.014) | not scorable | 10 / 2 / 7 | 0 of 4,264 |

The 2026-11-05 lowest-`J` point is `minCutoff 1.0`, `beta 0.00`, `dCutoff 0.5`: `J = 1.009 mm`, `J_D = 0.000 mm` because no sample is scorable, `L` slow 11 ms, median 6 ms, `t90 76.4 ms`. The tuner chose no constant and exited 1. The full dump is reproducible with the command below; it is not kept in the tree.

2026-11-05 segment summary (published defaults repeated; `—` means not measured):

| Segment | `J` before | `J` after | `J_D` before | `J_D` after | `L` median before | `L` median after | Peak `L` before | Peak `L` after | `t90` before | `t90` after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| still | 1.010 | 1.010 | — | — | — | — | — | — | — | — |
| held, drifting | — | — | — | — | — | — | — | — | — | — |
| slow pan | — | — | — | — | 10 | 10 | 10 | 10 | — | — |
| medium pan | — | — | — | — | 2 | 2 | 2 | 2 | — | — |
| fast flick | — | — | — | — | 7 | 7 | 7 | 7 | 76.4 | 76.4 |
| occlusion | — | — | — | — | 1 | 1 | 3 | 3 | — | — |

`after` repeats the published defaults (`minCutoff = 1 Hz`, `beta = 0.02`, `dCutoff = 1 Hz`). The still run moves 15 x 8 x 16 mm peak to peak over 15 s and still wanders about 1.0 mm RMS in the last 10 s; the filter changes `J` by at most 0.005 mm across the grid, so the filter is not limiting. D has a median speed of 1.16 cm/s: 42 samples touch the 10-50 cm/s band in the first second, and none survive the one-second warm-up gate.

## Acceptance
Per runtime, from `filter-spec` rev 4 sections 1 and 8:

| Metric | Bar | Applies to |
|---|---|---|
| Jitter `J` (RMS from a 1 s moving mean; last 10 s of S, first 2 s and >2 cm/s dropped) | <= 0.5 mm | segment S, every runtime |
| Jitter `J_D` (residual from a 1 s quadratic; 10-50 cm/s samples only) | <= 0.75 mm | segment D, every runtime |
| Median lag `L` | <= 20 ms | medium and fast sweeps |
| Median lag `L` | <= 160 ms | slow sweeps, regression check only |

The synthetic vectors under `packages/wmr_tracking/test/fixtures/pose_filter_captures/synthetic/` are harness vectors, not captures. They are marked `kind: synthetic`, `app_commit: null`, `firmware_sha: null`, and must not choose constants.

## Capture protocol (6 runs)
`filter-spec` rev 4 section 8 maps segment names to speeds. Analysis bins samples by the measured speed and scores only samples within +/-25% of nominal. One run covers each scored class; one occlusion diagnostic follows. Hands alternate so both appear. A non-occlusion run shorter than 14 s counts as missing.

| # | Hand | Segment | Speed | How to perform | Duration | Scores |
|---|---|---|---|---|---|---|
| 1 | LEFT | S still | 0 | Rest the hand, forearm braced on a table; hand relaxed | 15 s | `J` |
| 2 | RIGHT | D held, drifting | 10-50 cm/s | Hold as if aiming; wander at 10-50 cm/s, not a slow drift | 15 s | `J_D` |
| 3 | LEFT | slow pan | 10 cm/s | Move 30 cm sideways in 3 s, back and forth; keep the body still | 18 s | `L <= 160 ms` |
| 4 | RIGHT | M medium pan | 50 cm/s | Move 50 cm sideways in 1 s, back and forth; keep the body still | 15 s | `L <= 20 ms` |
| 5 | LEFT | F fast flick | 150 cm/s | Flick 45 cm in 0.3 s, pause, return; keep the body still | 20 s | `L <= 20 ms` |
| 6 | RIGHT | occlusion | n/a | Aim, then hide the hand for a second or two | 15 s | diagnostic |

The occlusion run has no acceptance bar; it records reacquisition gaps. The tuner pools both hands per runtime and motion, so one run per class is enough. The `--full` lab preset asks for four runs per scored class per hand (42 runs, about 23 min) and is only for a per-hand replicate corpus.

Provenance per file: runtime (`androidXr`, `viture`, `xreal`), app commit, firmware short SHA, anchor rate and run index. The guided bench writes this automatically; a hand-made debug-screen recording needs the same fields to count.

## Guided bench
The guided bench (`apps/wmr_companion_app/lib/ui/bench/`) writes the 6-run corpus. Attach a hand-tracking runtime on the Debug screen, open **Guided bench run** from Connect, and choose **6DoF only** (no bridge) or **Combined**. The pose step records LEFT still, RIGHT drifting, LEFT slow pan, RIGHT medium pan, LEFT fast flick, RIGHT occlusion. Recordings are sampled once per new anchor frame; each `PoseRecording` carries the provenance block. Progress is saved after every run in `bench_pose_progress.json`; re-entering skips runs whose files are still on disk. Finish the wizard and export the test bundle. Files are named `pose_capture_<runtime>_<hand>_<segment>.json`.

## One command from bundle to tuning run
From `packages/wmr_tracking`:

```bash
# 1. convert the tester bundle into tuner captures
dart run tool/pose_capture_prepare.dart --bundle wmr-ext-20261030.zip

# 2. tune each runtime on the converted corpus
dart run tool/pose_filter_tune.dart \
  --captures build/pose_corpus/viture \
  --markdown build/pose_corpus/viture-grid.md
```

For a directory of `PoseRecording` JSON, pass `--captures path/to/recordings`; `--out` changes the default `build/pose_corpus`. A debug-screen recording has no provenance, so the tool warns and skips it. The tool writes `<runtime>/<hand>/<motion>/run<N>.json` plus `coverage.md`. It refuses an incomplete corpus with exit 1 and names every missing cell, for example `viture/mediumPan: 0 of 1 runs`, and writes nothing. A run shorter than 14 s also counts as missing. `--full` prints one row per runtime and hand.

Controller-only recordings do not close the gap: with no runtime anchor the fuser falls back to head-relative offset or orientation only, and those paths are never filtered. Attach Android XR, VITURE or XREAL while the bench records.

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

After a scorable hardware run, fill the table, copy the chosen constants into `PoseFilterConfig` and `SixDofFuser` defaults, and add the per-runtime map. Until then the defaults stay at the published values.
