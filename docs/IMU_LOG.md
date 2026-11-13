# Raw IMU log (`.wmrimu`)

Status: **specified, not implemented.** No recorder, reader or file of this
format exists in the code yet. This document is the format and the contract
for the code that will write and read it. Nothing here has been run on a
phone or against a bridge.

## Why

The app parses every FF12/FF14 record and then keeps none of them. The two
recorders that exist do not cover the gap:

- the Capture screen ([CAPTURE.md](CAPTURE.md)) stores raw FF11 frames as
  text, with the phone's arrival time only;
- the Latency screen ([LATENCY.md](LATENCY.md)) stores per-record timing rows,
  without gyro or accel.

Timeline alignment ([TIMELINE.md](TIMELINE.md)), fusion tuning, loss analysis
and any later camera work need the decoded IMU samples exactly as the bridge
sent them, with all three clocks: the controller's `device_ticks`, the
bridge's `rx_time_us` and the phone's arrival time. The log stores the wire
record verbatim so that nothing the app computes today limits what can be
analysed later.

## Scope

- Input: FF12 records and the records inside FF14 batches, from BLE or from
  the Pi WebSocket (`StreamMode.decoded` and `StreamMode.batched`).
- One file holds both hands and every bridge of one session.
- The log is a recording, not a transport: it is written on the phone and
  exported as a file.

## File

- Extension `.wmrimu`, binary, all integers little-endian, floats IEEE 754
  binary32 (only inside the embedded records and the `TRACK` record).
- Name: `imu-YYYYMMDD-HHMMSS-NNN.wmrimu`, local time of the session start and
  a three-digit segment number starting at `000`.
- Directory: `imu/` under the app documents directory (captures stay in the
  documents directory itself, latency runs in `latency/`).
- Layout: a 64-byte header, a JSON metadata block, then records until the end
  of the file. There is no index and no trailer; the file is valid after any
  flush.

### Header, 64 bytes

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | 8 | `magic` | ASCII `WMRIMULG` (`57 4D 52 49 4D 55 4C 47`) |
| 8 | u16 | `format_version` | `1`. A reader refuses a larger major version |
| 10 | u16 | `header_size` | `64`. A reader skips to this offset, so the header can grow |
| 12 | u32 | `meta_len` | Length of the JSON metadata in bytes, without padding. At most 65536 |
| 16 | u32 | `meta_crc32` | CRC-32 (IEEE 802.3, as FF13) of the `meta_len` metadata bytes |
| 20 | u32 | `segment_index` | 0 for the first file of a session, +1 per rotation |
| 24 | u64 | `start_unix_us` | Wall-clock time when this segment was opened, microseconds since the Unix epoch (for humans; never used for alignment) |
| 32 | u64 | `start_mono_us` | The transport's monotonic clock (`BleNotification.receivedAtUs`) when this segment was opened |
| 40 | 16 | `session_id` | Random bytes, the same in every segment of one session |
| 56 | u32 | `flags` | bit0 `HAS_TRACK` (the session may contain `TRACK` records). Other bits 0 |
| 60 | u32 | reserved | 0 |

### Metadata block

`meta_len` bytes of UTF-8 JSON (one object), followed by zero bytes up to the
next multiple of 8. Records start at
`header_size + ((meta_len + 7) & ~7)`. The metadata is written once per
segment and repeated in every segment.

| Key | Type | Content |
| --- | --- | --- |
| `app` | object | `name`, `version`, `build` |
| `platform` | object | `os`, `osVersion`, `model` |
| `clock` | object | `receivedAt`: `"transport monotonic, microseconds"`; `tickNs`: `100` |
| `streamMode` | string | `"decoded"` or `"batched"` at the start of the segment |
| `bridges` | array | One object per bridge, in the order of the record `bridge` index: `id` (the transport device id or the Pi `bridge_id`), `kind` (`"esp32"` or `"pi"`), `transport` (`"ble"`, `"ws"`), `firmware` (the FF16 version string), `mtu`, `connIntervalUs` (null when unknown), `bootId` (null until the bridge reports one) |
| `hands` | array | Two objects: `hand` (`"LEFT"`/`"RIGHT"`), `model` (`"wmr"`, `"psvr2"`, `"switch"`, from FF17), `calibrationCrc32` (the FF13 `crc32` of the block in use, or null), `calibrationApplied` (boolean) |
| `timeline` | object | The `SensorTimeline` configuration in use (window, regression length, clamp), or null |
| `label` | string | Free text entered by the operator, may be empty |

Rules for the metadata:

- It never contains the Monado config key, the de-obfuscated config block,
  the WebSocket token, or a full Bluetooth address. The config block is
  identified by its CRC-32 only.
- Unknown keys are ignored by a reader. A value that changes during the
  session (MTU, transport, firmware after an upgrade) is recorded as an
  `EVENT` at the time it changes; the metadata is the state at segment start.

### Record framing

Every record starts with the same 4 bytes:

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | u8 | `type` | Record type, below |
| 1 | u8 | `aux` | Per-type small field |
| 2 | u16 | `len` | Bytes that follow this 4-byte prefix |

A reader that does not know a `type` skips `4 + len` bytes. `len` above 4096
is a corrupt file. Records are not aligned and carry no per-record checksum.

| `type` | Name | `len` | Written |
| --- | --- | --- | --- |
| `0x01` | `IMU` | 64 | once per received record |
| `0x02` | `ECHO` | 36 | once per answered ping |
| `0x03` | `EVENT` | 16 + text | on link, stream and timeline events |
| `0x04` | `TRACK` | 48 | optional: once per headset pose sample |
| `0x05` | `MARK` | 8 + text | on an operator marker |
| `0x06` | `STATS` | 72 | every 5 s and once at close |

### `IMU` (0x01), 68 bytes in the file

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | u8 | `type` | `0x01` |
| 1 | u8 | `aux` | bits 0-1 `bridge` (index into `bridges`); bits 2-3 `source`: 0 FF12 over BLE, 1 FF14 over BLE, 2 decoded over WebSocket, 3 batched over WebSocket; bits 4-7 `batch_pos`: position of the record in its batch, 0 .. 8 (0 for a single record) |
| 2 | u16 | `len` | `64` |
| 4 | u64 | `received_at_us` | The transport's monotonic stamp of the notification or WebSocket message that carried the record. Every record of one batch has the same value |
| 12 | 56 | `record` | The FF12 version 1 record exactly as received, byte for byte ([PROTOCOL.md](PROTOCOL.md), "Record (version 1)") |

The first 12 bytes are the prefix fields (`type`, `aux`, `len`,
`received_at_us`); the remaining 56 are the wire record. `hand`, `flags`,
`sequence`, `rx_time_us`, `device_ticks`, gyro, accel and the input fields
are read from the embedded record with the normal parser
(`parseDecodedRecord`); they are not duplicated in the prefix.

What is written and what is not:

- Every value that has length 56 is written, including a record the parser
  rejects (unknown version, bad hand), so a parser bug cannot hide data. A
  value of another length is not written as `IMU`; it is counted and reported
  in the next `STATS` and as an `EVENT` (`bad_value`).
- The record is written before calibration, axis mapping, bias removal,
  Switch burst spacing or any timeline processing. The log is the input of
  the pipeline, never its output.
- A batch is unpacked: one `IMU` per record, `batch_pos` 0 first.

### `ECHO` (0x02), 40 bytes in the file

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | u8 | `type` | `0x02` |
| 1 | u8 | `aux` | bits 0-1 `bridge`; bit 7 set when the answer is a WebSocket `pong` and not an FF15 notification |
| 2 | u16 | `len` | `36` |
| 4 | u64 | `t1_us` | Phone monotonic time just before the ping was handed to the transport |
| 12 | u64 | `t4_us` | Transport stamp of the answer |
| 20 | 20 | `answer` | The FF15 version 1 answer as received. For a WebSocket `pong` the recorder builds the same 20 bytes: `ping_id` from `id`, `rx_time_us` from `serverTimeUs`, `turnaround_us` and `queue_depth` 0 |

Timeouts are not written as `ECHO`; they are counted in `STATS`.

### `EVENT` (0x03)

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | u8 | `type` | `0x03` |
| 1 | u8 | `aux` | bits 0-1 `bridge`; bits 2-3 `hand`: 0 LEFT, 1 RIGHT, 3 not hand-specific |
| 2 | u16 | `len` | `16 + n` |
| 4 | u64 | `at_us` | Phone monotonic time of the event |
| 12 | u16 | `code` | Below |
| 14 | u16 | reserved | 0 |
| 16 | u32 | `arg` | Per code |
| 20 | `n` | `text` | Optional UTF-8 detail, not terminated, at most 256 bytes. Never a token or an address |

| `code` | Name | `arg` |
| --- | --- | --- |
| 1 | `link_up` | 0 BLE, 1 WebSocket |
| 2 | `link_down` | 0 BLE, 1 WebSocket |
| 3 | `stream_on` | `source` value as in `IMU.aux` |
| 4 | `stream_off` | `source` value |
| 5 | `transport_switch` | new transport: 0 BLE, 1 WebSocket |
| 6 | `controller_connected` | FF17 model value |
| 7 | `controller_disconnected` | 0 |
| 8 | `timeline_epoch` | reason: 1 tick/rx disagreement over 100 ms, 2 `rx_time_us` went backwards, 3 `TICK_RESET` flag, 4 `controller_epoch` changed, 5 `boot_id` changed, 6 operator reset |
| 9 | `mtu` | negotiated ATT MTU |
| 10 | `conn_interval` | connection interval in microseconds |
| 11 | `writer_drop` | records dropped because the writer queue was full (since the last such event) |
| 12 | `boot_id` | the new `boot_id` |
| 13 | `calibration` | FF13 `crc32` of the block now in use |
| 14 | `bad_value` | length of a stream value that was not 56 bytes (or not `2 + 56 x count`) |
| 15 | `cap_reached` | 0; recording stopped because of the size cap |

Code 8 with reasons 3 to 5, and code 12, depend on protocol proposals P1 and P2
([PROTOCOL.md](PROTOCOL.md), "Protocol proposals") and are unused until a
bridge implements them. A reader ignores a code it does not know.

### `TRACK` (0x04), optional, 52 bytes in the file

Written only when a tracking source is active and the header has `HAS_TRACK`.
It lets a later analysis relate controller IMU to the headset pose without a
second file. It is the pose the tracking source delivered, not a fused
controller pose.

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | u8 | `type` | `0x04` |
| 1 | u8 | `aux` | Tracking source: 1 XREAL, 2 VITURE, 3 Android XR, 4 other |
| 2 | u16 | `len` | `48` |
| 4 | u64 | `at_us` | Phone monotonic arrival time of the pose |
| 12 | i64 | `source_time_ns` | The source's own timestamp, 0 if it has none |
| 20 | u32 | `flags` | bit0 position valid, bit1 orientation valid |
| 24 | 3 x f32 | `position` | metres, source frame |
| 36 | 4 x f32 | `orientation` | quaternion x, y, z, w, source frame |

### `MARK` (0x05)

`aux` 0, `len` = `8 + n`: `at_us` u64, then `n` bytes of UTF-8 label (at most
256). Used for operator notes and for the phases of a guided procedure
(`begin:still`, `end:still`), so one log can replace a text capture's phase
lines.

### `STATS` (0x06), 76 bytes in the file

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| 0 | u8 | `type` | `0x06` |
| 1 | u8 | `aux` | bit0 `final`: the last record of a cleanly closed session |
| 2 | u16 | `len` | `72` |
| 4 | u64 | `at_us` | Phone monotonic time |
| 12 | u32 | `echo_timeouts` | Pings without an answer since session start |
| 16 | u32 | `bad_values` | Stream values of a wrong length since session start |
| 20 | u64 | `records_written` | Records of every type handed to the file since session start |
| 28 | u64 | `records_dropped` | Records dropped by the writer queue since session start |
| 36 | u64 | `bytes_written` | Bytes handed to the file since session start, all segments |
| 44 | 2 x 16 | per hand, LEFT then RIGHT | `imu_records` u32, `sequence_gaps` u32 (missing sequence numbers), `out_of_order` u32, `tick_missing` u32 (`TickTimer.missing`) |

A file whose last record is not a `STATS` with `final` was not closed cleanly
(app killed, battery). It is still readable up to the last complete record.

## Size

An `IMU` record is 68 bytes. Two hands at 200 Hz are 400 records/s:
`400 x 68 = 27 200` bytes/s, `1 632 000` bytes/min, **about 1.63 MB/min**
(98 MB/h). `ECHO` at 4 pings/s adds 160 bytes/s and `STATS` 15 bytes/s; both
are below 1 %. With report loss on the controller link the rate is lower in
proportion. A `TRACK` stream at 60 Hz adds 3120 bytes/s (about 11 %).

## Writer

The recorder must never slow the path that receives notifications.

- **Hot path (receiving isolate).** Appending a record is a copy of at most
  68 bytes into a preallocated 16 KiB staging buffer. No allocation, no
  `await`, no file call. A full buffer, or a 50 ms timer, hands the buffer to
  the writer isolate as `TransferableTypedData` and takes the next one from a
  small pool.
- **Bounded queue.** At most 64 buffers (1 MiB, about 38 s of two hands) may
  be outstanding between the two isolates. When the limit is reached the new
  buffer is dropped whole, its records are counted in `records_dropped`, and
  a `writer_drop` event is written when the queue accepts data again. The
  receive path never waits for the writer.
- **Writer isolate.** Owns the file. It appends buffers in order and flushes
  to the OS **every 250 ms or after 64 KiB**, whichever comes first, so a
  killed app loses at most about a quarter of a second.
- **Rotation.** A segment is closed and the next one opened when it reaches
  **64 MiB or 30 minutes**, whichever comes first (at the nominal rate the
  time limit comes first, at about 49 MB). Rotation happens between records.
  The new segment repeats the header (with `segment_index` + 1) and the
  metadata, and the first `STATS` of the new segment follows at once.
- **Cap.** A session stops at **1 GiB** in total (about 11 hours at the
  nominal rate): the recorder writes `cap_reached`, a final `STATS`, closes
  the file and tells the user. It never deletes older files to make room.
  Recording does not start when the free space is below 128 MiB.
- **Close.** Stop, a link teardown and leaving the screen all flush the
  staging buffer, write the final `STATS` and close. A link drop alone does
  not end the session: it is a `link_down` event, and records continue when
  the link returns.
- **Errors.** A write error stops the recording, is shown to the user and is
  not retried. The stream is not affected.

## Reader and replay contract

A reader (`WmrImuReader`, pure Dart in `wmr_core`; a Python reader of the
same rules for desktop analysis):

1. checks the magic and `format_version`, reads `header_size` and `meta_len`,
   verifies `meta_crc32` (a mismatch is reported, the records are still
   read);
2. iterates records with the 4-byte prefix, skipping unknown types;
3. stops without error at the first record that is not complete (truncated
   tail) and reports the byte offset and whether a final `STATS` was seen;
4. treats several segments with the same `session_id` as one stream, ordered
   by `segment_index`; a missing segment is a reported gap, not an error.

Replay feeds the records back in file order:

- An `IMU` record is delivered as the same 56 bytes with the same
  `received_at_us`, grouped into the original batches by `batch_pos` (a new
  batch starts at `batch_pos` 0), so `ControllerService`, `TickTimer`,
  `SensorTimeline` and the fusion see what they saw live.
- `ECHO`, `EVENT` and `TRACK` records are delivered at their place in the
  order of the file.
- Replay does not depend on wall-clock time: it can run as fast as the
  consumer reads, and two replays of one file give identical results.

Invariants a test can check on any file (they are the pass criteria in
[TEST_PLAN_PI_WMR.md](TEST_PLAN_PI_WMR.md), M5):

- per hand, the number of `IMU` records equals the sequence span (last minus
  first plus one, modulo 2^32) minus the missing sequence numbers, plus
  duplicates (a Switch hand repeats each sequence three times);
- `received_at_us` never decreases in file order;
- the final `STATS` counters equal a recount from the records;
- the `record` bytes of the golden `ff11_frames[].record_hex`
  (`wmr_golden_v1.json`) survive a write and a read unchanged.

## Coexistence with the text capture (`wmr-capture v1`)

The existing recorder is unchanged. Checked against
`packages/wmr_core/lib/services/capture_recorder.dart` and
`capture_files.dart`:

| | Text capture | Raw IMU log |
| --- | --- | --- |
| Code | `CaptureRecorder`, `CaptureFormat`, `FileCaptureSink` | not implemented |
| Format | UTF-8 text, first line `# wmr-capture v1`, header comment lines (`source`, `hand`, `mtu`, `started`), `@begin`/`@end` phase lines, one `F <seconds> <hand> <sequence> <92 hex digits>` line per frame | binary, this document |
| Content | raw 46-byte FF11 frames of the hand the operator chose | decoded FF12/FF14 records of both hands |
| Stream | needs `StreamMode.raw` (FF11) | needs `decoded` or `batched` |
| Clock | phone arrival time relative to the file's start, six decimals | absolute transport monotonic microseconds, plus the bridge and controller clocks inside each record |
| Files | `left-YYYYMMDD-HHMMSS.txt` / `right-...txt` in the documents directory | `imu-YYYYMMDD-HHMMSS-NNN.wmrimu` in `imu/` |
| Consumer | WMR_Bridge `tools/analyze_capture.py` | the replay reader |
| Flush | none until close (`FileCaptureSink.add` only queues text) | every 250 ms or 64 KiB |

FF11, FF12 and FF14 are mutually exclusive on a bridge, so the two recorders
cannot record the same bridge at the same time. The Capture screen switches
the service to raw first; starting a capture therefore stops a running IMU
log with a `stream_off` event followed by the final `STATS`, and the UI says
so. The two formats do not replace each other: the text capture is the input
of the rotation analysis in WMR_Bridge `docs/DECODING.md`, the IMU log is the
input of timing and fusion work.

## Privacy

A log contains controller motion and button input and, in the metadata, the
phone model and bridge ids. It is stored in app-private storage and leaves
the phone only through an explicit export. It never contains the session
token, the config key or the config block.

## Not decided here

- Compression (the records compress well; a later `format_version` can add a
  compressed block type).
- Whether raw FF11 frames get a record type of their own, which would let one
  file replace the text capture.
- An index for seeking in long sessions.
