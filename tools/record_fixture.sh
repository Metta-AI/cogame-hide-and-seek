#!/bin/bash
# Records one hide-and-seek episode as a .bitreplay fixture, driving the real
# server and the real seat registrar exactly as the platform does.
#
# Usage: tools/record_fixture.sh <out.bitreplay> <seed> [extraConfigJson]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; EXTRA="${3:-}"; PORT="${PORT:-21000}"
[ -z "$EXTRA" ] && EXTRA='{}'
BIN="${BIN:-./hide-and-seek}"
PLAYER_BIN="${PLAYER_BIN:-./hide-and-seek-player}"
[ -x "$BIN" ] || { echo "build the game first: nim c -d:release --path:src -o:$BIN src/hide_and_seek.nim" >&2; exit 1; }
[ -x "$PLAYER_BIN" ] || { echo "build the player first: nim c -d:release --path:src -o:$PLAYER_BIN src/hide_and_seek_player.nim" >&2; exit 1; }

CFG=$(mktemp /tmp/hns-fixture-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$EXTRA" <<'PY'
import json, sys
manifest = json.load(open("coworld_manifest_template.json"))
cfg = dict(manifest["certification"]["game_config"])
cfg["seed"] = int(sys.argv[2])
cfg["tokens"] = ["token-%d" % i for i in range(cfg["num_agents"])]
cfg.update(json.loads(sys.argv[3]))
json.dump(cfg, open(sys.argv[1], "w"))
PY
SEATS=$(python3 -c "import json;print(json.load(open('$CFG'))['num_agents'])")

LOG="${LOG:-/tmp/hns-fixture-server-$$.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
"$BIN" > "$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the port to actually listen before spawning seats — a slow start
# would otherwise strand them and hang the lobby forever, silently.
for _ in $(seq 1 60); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "server died during startup; log tail:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened" >&2; tail -20 "$LOG" >&2; exit 1; }

PLAYER_PIDS=()
for i in $(seq 0 $((SEATS - 1))); do
  if [ $((i % 2)) -eq 0 ]; then SCRIPTED=burrow; else SCRIPTED=scatter; fi
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=token-$i" \
  PLAYER_SCRIPTED="$SCRIPTED" PLAYER_POLICY_LABEL="$SCRIPTED" \
    "$PLAYER_BIN" >> "$LOG" 2>&1 &
  PLAYER_PIDS+=($!)
done

wait $SERVER_PID || true
for pid in "${PLAYER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
rm -f "$CFG"
ls -l "$OUT"
