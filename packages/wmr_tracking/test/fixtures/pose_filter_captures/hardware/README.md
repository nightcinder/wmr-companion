# Hardware pose captures

Real `wmr-pose-capture` v1 traces, converted from ONY-249 `PoseRecording`
files by `tool/pose_capture_prepare.dart`. Unlike `../synthetic/`, these are
hardware data and may be used for tuning.

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
