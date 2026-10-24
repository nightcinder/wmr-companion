#!/usr/bin/env bash
# Real-socket loopback run of the app service layer (ControllerService)
# against the WMR_Bridge Pi daemon in --replay mode. No Pi, no controllers and
# no Bluetooth: the daemon decodes the captured reports and serves the same
# FF11/FF12/FF14 payloads over its WebSocket.
#
#   WMR_BRIDGE_DIR=/path/to/WMR_Bridge ./tool/loopback_service_check.sh
#
# Environment:
#   WMR_BRIDGE_DIR  WMR_Bridge checkout (default: sibling ../../../WMR_Bridge)
#   PORT            loopback port (default 8799)
#   DURATION        capture length in ms (default 6000)
#   STREAM          raw | decoded | batched (default batched)
#   TOKEN           shared token, when the daemon requires one
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app=$(cd "$here/.." && pwd)
root=$(cd "$app/../.." && pwd)
bridge_dir=${WMR_BRIDGE_DIR:-$root/../WMR_Bridge}
port=${PORT:-8799}
duration=${DURATION:-6000}
stream=${STREAM:-batched}
token=${TOKEN:-}

if [[ ! -d "$bridge_dir/pi/wmr_bridge" ]]; then
  echo "WMR_BRIDGE_DIR does not contain pi/wmr_bridge: $bridge_dir" >&2
  echo "set WMR_BRIDGE_DIR to the WMR_Bridge checkout" >&2
  exit 2
fi

log=$(mktemp)
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$log"
}
trap cleanup EXIT

seconds=$(( (duration + 3999) / 1000 ))
echo "starting wmr_bridge --replay on port $port for $((seconds + 4))s"
(
  cd "$bridge_dir/pi"
  exec python3 -m wmr_bridge \
    --bind 127.0.0.1 \
    --port "$port" \
    --replay "$bridge_dir/samples/controller_frames.txt" \
    --duration "$((seconds + 4))" \
    ${token:+--token "$token"} \
    --log-level INFO
) >"$log" 2>&1 &
pid=$!

ready=0
for _ in $(seq 1 100); do
  if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 0.2)" "$port" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  echo "wmr_bridge did not open port $port" >&2
  cat "$log" >&2
  exit 1
fi

set +e
extra=()
if [[ -n "$token" ]]; then
  extra=(--token "$token")
fi
(
  cd "$app"
  dart run tool/loopback_service_check.dart \
    --host 127.0.0.1 \
    --port "$port" \
    --stream "$stream" \
    --duration "$duration" \
    "${extra[@]}"
)
status=$?
set -e

echo "--- wmr_bridge log (tail) ---"
tail -n 20 "$log"
exit "$status"
