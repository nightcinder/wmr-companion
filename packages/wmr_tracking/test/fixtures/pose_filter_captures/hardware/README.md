# Hardware pose captures

Real `wmr-pose-capture` v1 traces, converted from  `PoseRecording`
files by `tool/pose_capture_prepare.dart`. Unlike `../synthetic/`, these are
hardware data and may be used for tuning.

## Android XR / Google Aura, 2026-11-05 — complete 6-run corpus, invalid protocol

Source: `wmr-ext-20261105.zip` from the external tester, Android XR on a Google
Aura (Android 14 / API 34), app 0.3.16 (versionCode 2021) at commit `903f03f`,
no bridge attached so `firmware_sha` is null. `androidXr-20261105/` holds six
runs, one per class, hands alternating, 144 Hz and 26 joints:

| File | Segment | Samples | Span |
|---|---|---:|---:|
| `androidXr-20261105/left/still/run1.json` | still | 2170 | 15.0 s |
| `androidXr-20261105/right/heldDrift/run1.json` | held, drifting | 2168 | 15.0 s |
| `androidXr-20261105/left/slowPan/run1.json` | slow pan | 2606 | 18.0 s |
| `androidXr-20261105/right/mediumPan/run1.json` | medium pan | 2172 | 15.0 s |
| `androidXr-20261105/left/fastFlick/run1.json` | fast flick | 2394 | 20.0 s |
| `androidXr-20261105/right/occlusion/run1.json` | occlusion | 400 | 2.8 s |

`pose_capture_prepare.dart` accepts it as a complete default corpus (exit 0),
but it does not follow `filter-spec` rev 4 section 8. The release at
`903f03f` predates this branch's bench-prompt fix, so the tester was told to
brace an arm rather than rest the forearm on a table, and to "let the
controller wander slowly" rather than move at 10-50 cm/s. S still improves
over 2026-11-03 (`J = 1.009 mm`, 15 x 8 x 16 mm peak to peak) but is not a
table-braced hold. D stays at a median 1.16 cm/s: 42 samples touch the
10-50 cm/s band, all during the first second's settle, so none pass the
tuner's one-second warm-up gate and `J_D` is **unscorable**, not 0 mm.

The full 4,264-point grid is summarised in
`docs/runs/sheets/pose-filter.md` and is reproducible with the command there.
No point passes and no constant was chosen. Do not tune from this corpus;
record again with a
build that contains the section 8 prompts.

## Android XR / Google Aura, 2026-11-03 — complete 6-run corpus

Source: `wmr-aura-0.3.15-test-20261103.zip` from the external tester, Android XR
auto-detected on a Google Aura (Android 14 / API 34), app 0.3.15 (versionCode
2020) at commit `591ac18`, no bridge attached so `firmware_sha` is null.
`androidXr-20261103/` holds the six prepared traces, one run per class, hands
alternating, 143 Hz and 26 joints:

| File | Segment | Samples | Span |
|---|---|---:|---:|
| `androidXr-20261103/left/still/run1.json` | still | 2136 | 15.0 s |
| `androidXr-20261103/right/heldDrift/run1.json` | held, drifting | 2138 | 15.0 s |
| `androidXr-20261103/left/slowPan/run1.json` | slow pan | 2475 | 17.3 s |
| `androidXr-20261103/right/mediumPan/run1.json` | medium pan | 2131 | 15.0 s |
| `androidXr-20261103/left/fastFlick/run1.json` | fast flick | 2870 | 20.0 s |
| `androidXr-20261103/right/occlusion/run1.json` | occlusion | 1359 | 15.0 s |

`pose_capture_prepare.dart` accepts it as a complete default corpus (exit 0).
The full 4,264-point grid was replayed under 's addendum: **no point
passes.** `J` is 1.514 mm against 0.5 mm and `J_D` is 7.576 mm against
0.75 mm; the grid spread is under 0.04 mm. Lag passes (slow 10 ms, medium
1 ms, fast 7 ms). The still run was hand-held, not braced, and the drifting
run's median speed was 2.9 cm/s, so only 43 samples were in segment D's
10-50 cm/s band. The grid is summarised in `docs/runs/sheets/pose-filter.md`. Do not choose
constants from this corpus; recapture S braced and D in band first.

## Android XR / Google Aura, 2026-11-02

Source: `wmr-aura-androidxr-test-20261102.zip` from the external tester,
Android XR runtime auto-detected on a Google Aura headset, app 0.3.14
(versionCode 2019) at commit `a9b0ddc`, no bridge attached so
`firmware_sha` is null. Left hand only.

| File | Segment | Anchor samples | Span | Note |
|---|---|---:|---:|---|
| `androidXr/left/still/run1.json` | still | 4113 | 30.0 s | accepted |
| `androidXr/left/still/run2.json` | still | 3978 | 28.0 s | short of the 30 s section 8 minimum |

The tester's third file (`run4`, recorded as still) had 3927 of 4260 viewer
samples with no tracked left hand and moves across 0.5 m, so it is not a hold
and is not included. The remaining classes (held drifting, slow, medium, fast,
occlusion) were skipped.

At the published defaults both files give `J` of 4.814 mm and 16.230 mm; the
best point in the whole 4,264-point grid is 16.224 mm against the 0.5 mm bar.
Both runs move at 2.4-5.4 cm/s at the 90th percentile between samples, so they
are not a valid static hold. Do not use them to choose constants.
