#!/usr/bin/env bash
# Shared helpers for the Tank Squads test harness.
# Never touches the live server: own port, own rcon port, own mod dir, own map.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/test/.work"
FACTORIO="${FACTORIO:-$WORK/engine/factorio/bin/x64/factorio}"
MODS="$WORK/mods"
MAP="${TANK_SQUADS_TEST_MAP:-$WORK/test-map.zip}"
PORT=34198
export TS_RCON_PORT=27016
export TS_RCON_PW=tanksquads
SERVER_PID=""

setup_sandbox() {
  if [ ! -x "$FACTORIO" ]; then
    echo "Missing isolated Factorio executable: $FACTORIO"
    echo "Install a separate test engine under test/.work/engine, or set FACTORIO explicitly."
    return 1
  fi
  # game.server_save() fails on a fresh checkout without the saves directory.
  mkdir -p "$WORK" "$MODS" "$WORK/saves"
  ln -sfn "$ROOT" "$MODS/tank-squads"
  cat > "$WORK/config.ini" <<EOF
[path]
read-data=__PATH__executable__/../../data
write-data=$WORK
[general]
locale=auto
EOF
  if [ ! -f "$MAP" ]; then
    "$FACTORIO" --config "$WORK/config.ini" --mod-directory "$MODS" \
      --create "$MAP" >"$WORK/create.log" 2>&1
  fi
}

start_server() {
  # Refuse occupied ports before starting. Never send RCON commands to an
  # already-running process, and never stop a process this harness did not start.
  python3 - "$PORT" "$TS_RCON_PORT" <<'PY'
import socket, sys
for port, kind in [(int(sys.argv[1]), socket.SOCK_DGRAM), (int(sys.argv[2]), socket.SOCK_STREAM)]:
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("0.0.0.0", port))
PY
  if [ "$?" -ne 0 ]; then return 1; fi
  "$FACTORIO" --config "$WORK/config.ini" --mod-directory "$MODS" \
    --start-server "$MAP" --server-settings "$ROOT/test/server-settings.json" \
    --port "$PORT" --rcon-bind 127.0.0.1:$TS_RCON_PORT --rcon-password "$TS_RCON_PW" \
    >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    if grep -q "Starting RCON interface" "$WORK/server.log" 2>/dev/null; then
      # A fresh disposable map consumes the first console command to confirm
      # disabling achievements. Prime with a harmless command before tests.
      python3 "$ROOT/test/rcon.py" "/silent-command rcon.print('test-ready')" >/dev/null
      [[ "$(python3 "$ROOT/test/rcon.py" "/silent-command rcon.print('test-ready')")" == "test-ready" ]]
      return $?
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "SERVER DIED ON STARTUP:"; tail -20 "$WORK/server.log"; return 1
    fi
    sleep 1
  done
  echo "SERVER DID NOT START:"; tail -20 "$WORK/server.log"; return 1
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

# run_case <file> -> prints PASS/FAIL line, returns 0/1
run_case() {
  local f="$1" name body out attempt
  name="$(basename "$f" .lua)"
  body="$(tr '\n' ' ' < "$f")"
  # Combat tests need real engine ticks between assertions. WAIT is bounded
  # and explicit; a timeout fails rather than silently skipping the case.
  for attempt in $(seq 1 100); do
    out="$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local ok, result = pcall(function() $body end) rcon.print(ok and (result or 'PASS') or ('FAIL: ' .. tostring(result)))")"
    if [[ "$out" != WAIT:* ]]; then break; fi
    sleep 0.1
  done
  case "$out" in
    PASS*) echo "$out  $name"; return 0 ;;
    SKIP*) echo "$out" | sed "s/^/SKIP  $name: /"; return 2 ;;
    *)     echo "$out" | sed "s/^/FAIL  $name: /"; return 1 ;;
  esac
}
