# wmr_ws

WebSocket (Wi-Fi) transport for the [WMR Bridge](https://github.com/nightcinder/WMR_Bridge)
Linux/Raspberry Pi daemon, behind the existing `BleTransport` seam from
`wmr_core`.

The daemon ([WMR_Bridge PR #47](https://github.com/nightcinder/WMR_Bridge/pull/47))
keeps the controller-facing Bluetooth Classic link and sends the **same FF11
fragments, FF12 records and FF14 batches** over a WebSocket instead of BLE
GATT. This package only replaces the link: `ControllerService`, the FF11
reassembler, the FF12 parser, the FF14 parser and `EchoClient` are reused
unchanged.

Status: **protocol 1 client, host-tested.** It has been run end to end against
`wmr_bridge --replay` on a loopback socket. No Raspberry Pi and no controllers
were involved, and nothing here is a hardware claim. Whether a Pi's Classic
radio beats the ESP32's is an open measurement question in WMR_Bridge
`docs/PI_BRIDGE.md`.

## Use

```yaml
dependencies:
  wmr_ws:
    path: packages/wmr_ws
```

```dart
import 'package:wmr_companion/wmr_companion.dart';
import 'package:wmr_ws/wmr_ws.dart';

final transport = WmrWsTransport(
  endpoints: [
    WmrWsEndpoint(host: 'wmr-pi.local', token: 'shared-secret'),
  ],
);
final wmr = WmrCompanion(ble: transport);
final id = 'wmr-pi.local:8765';
await transport.connect(id);
final controller = ControllerService(transport, id, mode: StreamMode.batched);
await controller.start();
```

There is no discovery: `WmrWsEndpoint` carries the host and port, and
`scan()` just reports the configured endpoints so the existing scan flow keeps
working. mDNS/zeroconf and automatic endpoint discovery remain follow-ups, not
part of this package; the reference app's Connect screen Wi-Fi `host:port` entry
landed in PR #62 (M14.3).

## The seam, and where it leaks

| `BleTransport` | Wi-Fi |
| --- | --- |
| endpoint | `ws://<host>:8765/wmr`, `Sec-WebSocket-Protocol: wmr-wifi-v1` |
| `connect` | socket, then the daemon's `hello`; if `authRequired`, `auth` within five seconds or it closes with 4401 |
| `discoverServices` | FF10 synthesized from `hello.streams` (`raw`→FF11, `decoded`→FF12, `batched`→FF14), plus FF15 and FF16 |
| `subscribe` | `subscribe` with the stream name; `stream_active` becomes `BleStreamException` / `BleStreamFaultKind.otherStreamActive` |
| `unsubscribe` | `{"type":"unsubscribe"}`; switching streams unsubscribes first, like zeroing the old CCC |
| `read(FF16)` | `hello.version`, no round trip |
| FF15 | JSON `ping` / `pong`; the 20-byte FF15 answer is synthesized for `EchoClient` |
| `connectionInfo().mtu` | `hello.fragmentCapacity` (raw fragment value size) |
| `connectionInfo().rssi`, `.connectionIntervalUs`, `.phy` | **null**: a WebSocket has no link-layer measurements |
| `scan` | the configured host:port only |
| FF11 status read | not synthesized; use `WmrWsTransport.status()` |
| FF13 calibration | **not implemented by the daemon**; absent from `discoverServices`, and `read`/`write` throw `WmrWsUnsupportedException` |

`ConfigClient` already treats an absent FF13 characteristic as
`ConfigReadFailure.unsupported`, so no new error path is needed.

### Null means not observable

ONY-98 established that a null link parameter means "this transport cannot see
it", not "use a placeholder". Wi-Fi has no RSSI, connection interval or PHY, so
all three stay null. `mtu` is filled because the daemon really does report a
fragment capacity; it is a payload size, not an ATT MTU.

### Clocks

- `BleNotification.receivedAtUs` is stamped from the transport's
  `MonotonicClock` at the first statement of the socket callback, before JSON
  typing, stream lookup, queueing or any consumer callback. A frame that waits
  in the client queue keeps its arrival time.
- `hello.version` is the bridge software version (FF16 equivalent), not
  controller firmware.
- The daemon's `serverTimeUs` (and FF12 `rx_time_us`) is its monotonic clock
  since *its* start. It is not comparable with the phone clock or with ESP32
  `esp_timer` values; only differences within one clock are meaningful.
- The FF15 answer's `rxTimeUs` is `serverTimeUs`; `turnaroundUs` and
  `queueDepth` are 0 because protocol 1's `pong` carries neither. `EchoSample`
  still reports the observable end-to-end round trip. `EchoSample.offsetUs`
  means "daemon clock minus phone clock", not "ESP32 minus phone clock"; it is
  a different quantity from the BLE bridge's offset, so do not compare the two
  bridges' offsets.

### Reconnect and sequence reset

There is no hidden auto-reconnect. Call `connect()` again and then
`ControllerService.start()` again, exactly as with BLE. The daemon resets its
per-hand sequence numbers only on daemon start; a controller reconnect does
not. `ControllerService.start()` rebaselines sequence and loss windows, so a
daemon restart after reconnect is not reported as catastrophic loss. The
reconnect tests in `test/reconnect_test.dart` pin that.

### Queue behaviour

The daemon has a 512-message queue per client and drops the **newest** message
when full. The client does the same with `WmrWsTransport.queueSize` and counts
the losses in `statsFor(deviceId).droppedByQueue`, so a slow consumer is
visible rather than an unbounded heap. Every frame passes through that queue
and is paced into the stream one at a time, so a synchronous consumer that is
slow, unpaused or not yet attached cannot grow the stream controller's internal
buffer. An asynchronous `onData` that returns before it has consumed a frame
can still hold already-delivered events in the controller; `ControllerService`
is synchronous, which is the contract this transport is written for. `WmrWsTransport.status()` exposes the
daemon's own `dropped`/`delivered` counters.

## Tests

```sh
dart test
```

The tests speak to an in-process WebSocket server on a real loopback socket
(`test/fake_pi_server.dart`), covering the handshake, auth success, rejection
and timeout, `stream_active`, stream switching, queue drops, arrival-time
stamps, FF11 reassembly, FF12/FF14 decoding through `ControllerService`, FF15
echo, FF16/FF13 reads and reconnect/rebaseline.

## Real loopback run

The optional, hardware-free end-to-end check starts the Pi daemon in replay
mode and drives it with `WmrWsTransport`:

```sh
WMR_BRIDGE_DIR=/path/to/WMR_Bridge ./tool/loopback_check.sh
```

It needs a WMR_Bridge checkout (for `samples/controller_frames.txt` and the
daemon) and Python 3.10+. It is not part of Dart CI because it is cross-repo;
the output is pasted into the pull request instead. See the PR for the actual
counters from the run used for this change.
