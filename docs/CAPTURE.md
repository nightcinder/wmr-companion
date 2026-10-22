# Raw capture (phone)

The Capture screen records raw controller frames in the text format of
WMR_Bridge `tools/capture_ble.py`, so `tools/analyze_capture.py` reads phone
captures unchanged. **Not verified on hardware**: nothing here has been run
against a phone with a real bridge, and no capture produced by the app has
been fed to the real `analyze_capture.py`.

## Where the format comes from

Read (read-only) from WMR_Bridge PR 6, branch `link-diagnostics` (the PR that
adds the MTU to the header): `tools/capture_ble.py`, `tools/analyze_capture.py`,
`docs/DECODING.md`. If that branch changes, re-read it and update this file and
`lib/services/capture_recorder.dart` together.

## File format

Text, UTF-8, `\n` line endings.

```
# wmr-capture v1
# source: BLE FF11 raw stream via wmr_companion app (phone)
# hand: LEFT (as stated by the operator)
# mtu: 517
# started: 2026-10-21T09:08:07
@begin still t=0.000000
F 0.013251 0 8231 a1010e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b
F 0.014000 1 500 a1010f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c
@end still t=0.100000
```

- Header: comment lines `# key: value`. `analyze_capture.py` reads them as
  metadata (`mtu`, `hand`, `started`); only `mtu` is reported. The desktop
  tool writes `source: BLE FF11 raw stream via tools/capture_ble.py`; the app
  writes the line above instead. `mtu` is the negotiated ATT MTU, or the
  word `unknown`. `hand` is `LEFT` or `RIGHT` as chosen by the operator.
  `started` is local time, `YYYY-MM-DDTHH:MM:SS`.
- `@begin <phase> t=<seconds>` and `@end <phase> t=<seconds>`, seconds with six
  decimals.
- `F <seconds> <hand> <sequence> <hex>`: receive time in seconds (six
  decimals), hand `0` = LEFT / `1` = RIGHT, the per-hand u32 sequence number
  in decimal, and the 46-byte frame as 92 lowercase hex digits (`a1 01` +
  44 payload bytes). One frame per line, both hands, only between a `@begin`
  and its `@end`.
- The analyzer ignores blank lines and `#` lines, reports frames outside a
  phase, bad hex, and frames that are not 46 bytes starting `A1 01` as
  problems, and filters by `--hand` itself.

### Time base

Desktop: `time.perf_counter() - t0`. App: the transport's monotonic
`Stopwatch` (`BleNotification.receivedAtUs`, the stamp of the last fragment of
the frame) minus its value when the capture file was opened. Phase markers use
the same clock, read when the user finishes the countdown or taps Finish. The
ESP32 has no timestamp in this stream; sequence numbers are the loss signal.

### Phases

Same names and order as `PHASES` in `capture_ble.py` (the analyzer keys on the
names), and the same instruction text except `twist_cw`, which the app words as
a physical motion description. The wording does not verify any axis sign:

| Phase | Instruction (line breaks folded) |
| --- | --- |
| `still` | Hold the controller still and upright: ring at the top, trigger facing away from you, as if aiming forward. Do not touch the buttons. Keep still for at least 5 seconds after pressing Enter. |
| `twist_cw` | Hold the controller with the buttons facing you, then twist it to the right about its handle: the trigger side swings to your right and the button side swings to your left. ONE full 360-degree turn, slowly (about 4 seconds), ending in the same pose. |
| `flip_away` | Start upright and facing away. Tip the top of the ring away from you and over: a forward somersault of the controller. ONE full 360-degree turn, slowly (about 4 seconds), ending in the same pose. |
| `lean_right` | Start upright and facing away. Tip the top of the ring to YOUR right and over: a cartwheel to the right. ONE full 360-degree turn, slowly (about 4 seconds), ending in the same pose. |

The desktop tool has no fixed durations or countdown: the operator presses
Enter to begin and Enter to end each phase. "Enter" in the `still` text means
the begin action.

### Differences in the app

- A 3-second countdown runs after "Begin" and before `@begin`; it is not
  recorded. The `@begin` marker is written when it reaches zero.
- Finish is a button. For `still` it is disabled for the first 5 seconds
  (the instruction's minimum); the other phases have no minimum.
- Only complete frames of exactly 46 bytes are written. Other lengths are
  counted on screen as skipped and not written.
- The `source` header line differs (see above).
- Per-phase link statistics port `LinkStats` from `capture_ble.py`
  (frames, gap events, missing, loss %, effective Hz = (frames-1)/span,
  produced Hz = (frames+missing-1)/span, out-of-order), restarting at each
  phase, with the same 5 % loss warning. The desktop tool's whole-run summary
  is not shown: it counts gaps between phases, when nothing is recorded.

## Implementation

- `lib/services/capture_recorder.dart`: format, phases, statistics,
  `CaptureRecorder`, `CaptureSink`. Pure Dart; tests use `MemoryCaptureSink`.
- `lib/services/capture_files.dart`: `FileCaptureSink` (buffered `IOSink`;
  each frame is one short `write`, no flush) and `CaptureStore` (naming,
  listing).
- `lib/ui/capture/`: controller and screen. The recorder listens to
  `ControllerService.frames`; there is no second BLE subscription and the
  transport is untouched.
- Files go to the app documents directory (`path_provider`) as
  `left-YYYYMMDD-HHMMSS.txt` / `right-...`. The screen shows the full path
  for `adb pull`, lists saved captures and shares them with `share_plus`.
- Aborting a run leaves the partial file; a phase that was running has no
  `@end`.

## Tests

`test/services/capture_recorder_test.dart` compares the output byte for byte
with `test/fixtures/capture_golden.txt`, which was written by hand following
the desktop format (`%.6f` times, `bytes.hex()`). It was not produced by
running `capture_ble.py` or checked by `analyze_capture.py`. The tests also
cover the gap and Hz summary and 100,000 frames fed back to back.
`test/ui/capture_controller_test.dart` drives the whole guided run with a fake
frame stream and clock.
