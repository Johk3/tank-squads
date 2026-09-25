#!/usr/bin/env bash
# Isolated native combat benchmark. Usage: bash test/bench-weapons.sh [count] [idle|fire] [carrier|mixed|siege|flame] [xp]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
COUNT="${1:-200}"
MODE="${2:-fire}"
COMPOSITION="${3:-carrier}"
XP="${4:-0}"
[[ "$COUNT" =~ ^[0-9]+$ ]] && (( COUNT >= 1 && COUNT <= 1000 )) || exit 2
[[ "$MODE" == idle || "$MODE" == fire ]] || exit 2
[[ "$COMPOSITION" == carrier || "$COMPOSITION" == mixed || "$COMPOSITION" == siege || "$COMPOSITION" == flame ]] || exit 2
[[ "$XP" =~ ^[0-9]+$ ]] || exit 2
setup_sandbox
trap stop_server EXIT
start_server
SAVE="weapons-$COUNT-$MODE-$COMPOSITION-xp$XP"
LUA=$(cat <<LUA
local name = 'tank-squads-weapon-benchmark-$COUNT'
for _, surface in pairs(game.surfaces) do
  if surface.name:find('tank-squads-weapon-benchmark', 1, true) == 1 then for _, e in pairs(surface.find_entities()) do e.destroy{raise_destroy = true} end end
end
local s = game.surfaces[name] or game.create_surface(name, {width = 128, height = $COUNT * 4 + 64, autoplace_controls = {}})
for i = 1, $COUNT do s.request_to_generate_chunks({0, i * 4 - $COUNT * 2}, 1) end
s.force_generate_chunk_requests()
local tiles = {}
for x = -4, 42 do for y = -$COUNT * 2 - 4, $COUNT * 2 + 4 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
local f = game.forces['weapon-benchmark'] or game.create_force('weapon-benchmark')
f.set_cease_fire('enemy', '$MODE' == 'idle')
-- Targets must stay attackable (units skip indestructible entities) yet
-- survive the whole run: zero out every specialist's ammunition damage.
for _, category in pairs{'bullet', 'cannon-shell', 'flamethrower'} do f.set_ammo_damage_modifier(category, -1) end
f.set_gun_speed_modifier('bullet', 0)
local count = 0
for i = 1, $COUNT do
  local y = i * 4 - $COUNT * 2
  local kind = '$COMPOSITION'
  if kind == 'mixed' then kind = ({'carrier','siege','flame'})[(i-1)%3+1] end
  local unit = kind == 'carrier' and 'tank-squad-soldier-1' or 'tank-squad-' .. kind
  local distance = kind == 'siege' and 35 or kind == 'flame' and 8 or 12
  local a = s.create_entity{name = unit, position = {0, y}, force = f, raise_built = true}
  local target = s.create_entity{name = 'tank', position = {distance, y}, force = 'enemy'}
  if not (a and target and storage.weapons[a.unit_number]) then error('benchmark spawn failed') end
  if $XP > 0 then remote.call('tank-squads', 'veteran_add_xp', a.unit_number, $XP) end
  if '$MODE' == 'fire' then a.commandable.set_command{type = defines.command.attack, target = target, distraction = defines.distraction.none} end
  count = count + 1
end
rcon.print('spawned ' .. count)
LUA
)
OUT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ $LUA")
[[ "$OUT" == "spawned $COUNT" ]] || { echo "$OUT"; exit 1; }
sleep 6
if [ "$MODE" == fire ]; then
  ACTIVE=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local n=0 for _,r in pairs(storage.weapons) do if r.entity.valid and r.entity.surface.name=='tank-squads-weapon-benchmark-$COUNT' and r.last_shot and game.tick-r.last_shot<(r.aim_timeout or 60) then n=n+1 end end rcon.print(n)")
  [[ "$ACTIVE" == "$COUNT" ]] || { echo "Only $ACTIVE/$COUNT carriers fired"; python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ for _,r in pairs(storage.weapons) do if r.entity.valid and r.entity.surface.name=='tank-squads-weapon-benchmark-$COUNT' then rcon.print(serpent.line{tick=game.tick,last=r.last_shot,position=r.entity.position,command=r.entity.commandable.command,cease=r.entity.force.get_cease_fire('enemy')}) break end end"; exit 1; }
  INTACT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local n=0 for _,t in pairs(game.surfaces['tank-squads-weapon-benchmark-$COUNT'].find_entities_filtered{name='tank',force='enemy'}) do if t.health==t.max_health then n=n+1 end end rcon.print(n)")
  [[ "$INTACT" == "$COUNT" ]] || { echo "Only $INTACT/$COUNT targets undamaged; benchmark would lose targets mid-run"; exit 1; }
fi
python3 "$ROOT/test/rcon.py" "/silent-command game.server_save('$SAVE')"
sleep 3
stop_server
"$FACTORIO" --config "$WORK/config.ini" --mod-directory "$MODS" \
  --benchmark "$WORK/saves/$SAVE.zip" --benchmark-ticks 900 --benchmark-runs 3 \
  --benchmark-verbose all --benchmark-ignore-paused > "$WORK/$SAVE.out" 2>&1
python3 - "$WORK/$SAVE.out" <<'PY'
import csv, statistics, sys
rows = list(csv.reader(open(sys.argv[1])))
header = next(row for row in rows if 'scriptUpdate' in row)
for metric in ('wholeUpdate', 'entityUpdate', 'scriptUpdate'):
    if metric not in header:
        continue
    column = header.index(metric)
    values = [int(row[column]) / 1e6 for row in rows if len(row) == len(header) and row[0].startswith('t') and row[0][1:].isdigit()]
    assert len(values) == 2700, len(values)
    print(f'{sys.argv[1]}: {metric} mean={statistics.mean(values):.6f} ms/tick, max={max(values):.6f} ms/tick; {len(values)} ticks')
PY
