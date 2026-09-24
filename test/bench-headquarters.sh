#!/usr/bin/env bash
# Measure tick cost of mobile headquarters.
# Usage: test/bench-headquarters.sh [count] [mode] [ticks]
#   count : headquarters to spawn, 0-50 (0 is the baseline on the same map)
#   mode  : idle   - parked headquarters
#           travel - every headquarters drives east for the whole run, so its
#                    helpers are re-placed every few seconds
#           dense  - like travel, inside a 10x10 grid of ordinary roboports,
#                    so every re-placement joins and leaves a large network
#   ticks : benchmark length per run (default 900, three runs)
# Prints avg/p95/max wholeUpdate and avg scriptUpdate per tick in ms.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-10}"
MODE="${2:-travel}"
TICKS="${3:-900}"
[[ "$COUNT" =~ ^[0-9]+$ ]] && (( COUNT <= 50 )) || exit 2
[[ "$MODE" == idle || "$MODE" == travel || "$MODE" == dense ]] || exit 2

setup_sandbox
trap stop_server EXIT
start_server
SAVE="headquarters-$COUNT-$MODE"
LUA=$(cat <<LUA
local name = 'tank-squads-hq-benchmark'
local s = game.surfaces[name]
if s then for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
else s = game.create_surface(name, {width = 1024, height = 1024, autoplace_controls = {}}) end
s.request_to_generate_chunks({0, 0}, 12)
s.force_generate_chunk_requests()
local tiles = {}
for x = -300, 380 do for y = -260, 260 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
s.always_day = true
if '$MODE' == 'dense' then
  for i = 0, 9 do for j = 0, 9 do
    local p = {x = -216 + i * 48, y = -216 + j * 48}
    s.create_entity{name = 'roboport', position = p, force = 'player'}
    s.create_entity{name = 'electric-energy-interface', position = {p.x + 3, p.y}, force = 'player'}
    s.create_entity{name = 'substation', position = {p.x - 3, p.y}, force = 'player'}
  end end
end
local count = 0
for i = 1, $COUNT do
  local y = (i - ($COUNT + 1) / 2) * 10
  local hq = s.create_entity{name = 'tank-squad-headquarters', position = {-200, y}, force = 'player', raise_built = true}
  if not (hq and storage.headquarters[hq.unit_number]) then error('benchmark spawn failed') end
  hq.commandable.set_command(('$MODE' == 'idle') and {type = defines.command.stop, distraction = defines.distraction.none}
    or {type = defines.command.go_to_location, destination = {360, y}, radius = 2, distraction = defines.distraction.none})
  count = count + 1
end
rcon.print('spawned ' .. count)
LUA
)
OUT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ $LUA")
[[ "$OUT" == "spawned $COUNT" ]] || { echo "$OUT"; exit 1; }
# Let pathing settle and the first re-placements happen before saving.
sleep 6
python3 "$ROOT/test/rcon.py" "/silent-command game.server_save('$SAVE')"
sleep 3
# The sandbox map saves itself on exit. Leave no headquarters in it for the
# regression suite.
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local s = game.surfaces['tank-squads-hq-benchmark'] for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end game.delete_surface(s) rcon.print('cleaned')" >/dev/null
stop_server

nice -n 19 "$FACTORIO" --config "$WORK/config.ini" --mod-directory "$MODS" \
  --benchmark "$WORK/saves/$SAVE.zip" --benchmark-ticks "$TICKS" --benchmark-runs 3 \
  --benchmark-verbose all --benchmark-ignore-paused > "$WORK/$SAVE.out" 2>&1
H=$(grep -n "^tick,timestamp" "$WORK/$SAVE.out" | head -1 | cut -d: -f1)
sed -n "${H},\$p" "$WORK/$SAVE.out" | python3 -c '
import sys, csv
rows = list(csv.reader(sys.stdin))
head, data = rows[0], [r for r in rows[1:] if len(r) == len(rows[0]) and r[0][:1] == "t" and r[0][1:].isdigit()]
w, s = head.index("wholeUpdate"), head.index("scriptUpdate")
whole = sorted(int(r[w]) / 1e6 for r in data)
script = [int(r[s]) / 1e6 for r in data]
print("'"$SAVE"': %d ticks  wholeUpdate avg %.4f p95 %.4f max %.4f ms  scriptUpdate avg %.4f max %.4f ms" % (
  len(whole), sum(whole) / len(whole), whole[int(len(whole) * 0.95)], whole[-1], sum(script) / len(script), max(script)))
'
