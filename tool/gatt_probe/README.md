# Native Android GATT Probe (`tool/gatt_probe`)

Minimal, standalone native Android application (Kotlin) for measuring BLE round-trip latency and stream delivery directly on the Android Bluetooth stack (`BluetoothGattCallback`), bypassing Flutter, `universal_ble`, and the platform channel.

This tool provides the baseline measurement for Milestone 7.1 to resolve Milestone 5 (Flutter vs. native receive hot path) as specified in `docs/runs/sheets/latency-2.md` (ONY-23).

---

## What It Measures

- **Direct GATT Latency**: Stamps `SystemClock.elapsedRealtimeNanos()` at the earliest possible instant inside `BluetoothGattCallback.onCharacteristicChanged()`.
- **FF15 Echo Round-Trip**: Pings the bridge's FF15 echo characteristic at 50 ms, 250 ms, or 1000 ms intervals via `WRITE_TYPE_NO_RESPONSE`, recording send, write-return, and notification arrival times.
- **FF14 Batched Decoded Stream**: Unpacks 56-byte controller records from FF14 batches, estimating device tick loss, inter-arrival times, and stalls over 50 ms.
- **Identical Output Schema**: Emits the exact same `wmr-latency` version 2 JSON format and echo CSV as the companion app, enabling 1:1 comparison with zero conversion.

---

## Building and Installing

### 1. From CI Artifacts
Download the `wmr-gatt-probe-debug-apk` artifact from the latest GitHub Actions CI run on `main` or the PR branch, then install via `adb`:
```bash
adb install -r app-debug.apk
```

### 2. Building from Source
Requires JDK 17 and the Android SDK (API 35, build-tools 35.0.0):
```bash
cd tool/gatt_probe
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

To run unit tests:
```bash
cd tool/gatt_probe
./gradlew test
```

---

## Running Against the ONY-23 Latency Run Sheet

Follow the protocol in `docs/runs/sheets/latency-2.md`:

### 1. Fixed Setup (Once Per Session)
- **Phone**: Place in a fixed stand taped to the desk, screen up, ~1.0 m from the bridge.
- **Controllers**: Rest face-down and motionless on marked spots, ~0.5 m from the bridge.
- **Bridge**: Fixed position and orientation. Ensure no other BLE client is connected.

### 2. Main Interleaved Blocks (12 runs × 120 s)
Run the 3 interleaved blocks alternating between App and Probe to eliminate drift bias:
- **Block 1**: App (none) → **Probe (none)** → App (FF14) → **Probe (FF14)**
- **Block 2**: **Probe (none)** → App (none) → **Probe (FF14)** → App (FF14)
- **Block 3**: App (none) → **Probe (none)** → App (FF14) → **Probe (FF14)**

### 3. Running a Probe Measurement
1. Open **WMR GATT Probe** on the phone.
2. Ensure Bluetooth and Location permissions are granted.
3. Configure the run parameters:
   - **Stream Subscription**: Select **FF14 (Batched)** for streamed runs, or **None (Echo only)** for no-stream runs.
   - **Ping Interval**: Select **250 ms** for main blocks (or **50 ms** / **1000 ms** for the interval pass).
   - **Dual-bridge mode**: Leave unchecked for standard single-bridge tests.
4. Tap **Scan & Connect**. The probe connects to `WMR Bridge`, negotiates MTU 517, requests `CONNECTION_PRIORITY_HIGH`, and subscribes to the requested characteristics.
5. Wait ~30 s for link settle. Check the ESP32 serial console for the `STREAM` line (verify `conn=[15.00ms lat=… to=…]`, `mtu=517`, `sub=1`).
6. Tap **Start 120s Run**. The probe runs for exactly 120 seconds, updating metrics live.
7. At 120 s, the run stops automatically and records the end RSSI and summary.

---

## Exporting Results

On run completion, the probe automatically exports three files to the app's external files directory:
- `latency-YYYYMMDD-HHMMSS.json` (`wmr-latency` v2 format)
- `latency-YYYYMMDD-HHMMSS-echo.csv` (per-ping round-trip timing)
- `latency-YYYYMMDD-HHMMSS-samples.csv` (per-record frame arrival times)

### Retrieving via ADB
Pull the files directly to your host workstation:
```bash
adb pull /sdcard/Android/data/com.onyxlens.wmr.gattprobe/files/ .
```

### In-App Sharing
Tap **Share / Export Results** in the app to share the JSON and CSV files via Android's share sheet (Drive, email, etc.).

---

## Schema Verification

The exported JSON matches `wmr-latency` v2:
- Root fields: `format` (`"wmr-latency"`), `version` (`2`), `source` (`"wmr-gatt-probe (native Android)"`), `started`, `stream`, `duration_us`.
- `round_trip`: `measured` (boolean), `sent`, `answered`, `timeouts`, `failed_writes`, `rtt`, `end_to_end`, `turnaround`, `max_queue_depth`, `counters`, `ping_interval_us`.
- `link`: `mtu`, `rssi_start_dbm`, `rssi_end_dbm`, `connection_interval_us` (populated when the platform dispatches connection parameter updates, or null where the OS does not surface it), `high_priority_requested`.
- `hands`: per-hand records, arrivals, span, rate, `inter_arrival` percentiles, `stalls_over_50000us`, `sequence_gaps`, `missing_from_ticks`, `delay_above_window_min`, and `delay_variation`.
