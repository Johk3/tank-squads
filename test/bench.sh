#!/usr/bin/env bash
# Measure tick cost with N soldiers. Usage: test/bench.sh [count] [ticks] [mode]
#   count : number of tank-squad-soldier-1 to spawn (default 45)
#   ticks : benchmark length in ticks (default 900)
#   mode  : "" (idle, default), "patrol", or "scout" — "patrol" selects all
#           spawned soldiers into division 1 and starts a two-waypoint patrol
#           before saving, so the benchmark measures scriptUpdate cost while
#           units are actively pathing and re-issuing orders via
#           on_ai_command_completed. "scout" instead assigns them to division
#           1 and turns on scout mode, so the benchmark measures the cost of
#           scout.tick()'s per-sweep chunk search plus force.chart, and of
#           scout.on_command_completed reissuing legs.
#
# set -e note: this script is sourced against test/lib.sh, which itself sets
# `set -euo pipefail`. Because `source` runs in the current shell, lib.sh's
# errexit applies to the rest of this script regardless of what we declare
# here — a plain `set -uo pipefail` would be misleading, since the
# script actually runs with errexit on anyway. We declare `-euo pipefail`
# explicitly to match the real behaviour, and add `trap stop_server EXIT` (the
# same pattern run.sh uses) so that if any step fails partway through — an
# RCON call, the benchmark invocation itself — the sandbox server is still
# killed instead of leaking a background process holding port 34198/rcon 27016
# for the next run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-45}"
TICKS="${2:-900}"
MODE="${3:-}"

setup_sandbox
mkdir -p "$WORK/saves"  # game.server_save() errors with a "cannot make canonical path" if this is missing
trap stop_server EXIT
start_server || exit 1

# Fix round 1: the sandbox base map (test-map.zip, cached by setup_sandbox
# and reloaded on every start_server) is NOT pristine across invocations —
# stop_server's SIGTERM triggers Factorio's autosave-on-exit, which writes
# the current game state (every soldier/barracks spawned by the run that
# just finished) back into the loaded save file itself, not just into the
# named bench-*.zip. Confirmed live: running `bench.sh 45 ...` then
# `bench.sh 0 ...` left 45 leftover soldiers and 3 leftover barracks on the
# "0 soldiers" map (storage.barracks read back as 6, not 3). Clear every
# tank-squad-* entity at the start of each run.
#
# Note: entity.destroy{raise_destroy=true} raises script_raised_destroy, NOT
# on_entity_died — the mod only listens for on_entity_died (real combat
# death), so that flag does NOT run barracks.unregister()/squads.forget().
# Confirmed live: after switching to raise_destroy=true, a second cleanup
# run still read storage.barracks back as 9 (6 stale + 3 new) instead of 3.
# Fix: destroy plainly (no event needed) and reset storage.barracks directly
# through the mod's own script context immediately after, below.
python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] local removed=0 for _,e in pairs(s.find_entities_filtered{name={'tank-squad-soldier-1','tank-squad-soldier-2','tank-squad-soldier-3','tank-squad-barracks','tank-squad-rally-flag'}}) do e.destroy() removed=removed+1 end rcon.print('cleared '..removed)"
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ storage.barracks=nil storage.divisions=nil storage.unit_divisions=nil rcon.print('mod storage reset')"

# Fix round 1: at COUNT=200 the soldier line reaches x=600, well beyond the
# chunks generated around spawn by default (--create's default starting
# area). find_non_colliding_position silently returns nil on ungenerated
# ground. Confirmed live: before this fix, only 117/200 soldiers and 2/3
# barracks were actually created before this fix). Force-generate a box
# covering the whole soldier line plus slack for barracks offsets and the
# +-50 patrol waypoints before spawning anything.
python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] local n=$COUNT local half=math.max(n*1.5,50)+100 s.request_to_generate_chunks({half,0},math.ceil(half/32)+2) s.force_generate_chunk_requests() rcon.print('chunks generated')"

# Fix round 2 (2026-09-22, commit 6): the previous round placed 3
# tank-squad-barracks with raise_built=true (so barracks.tick() genuinely
# ran) but created NO tank-squad-rally-flag entities and left every
# barracks' inventory empty forever. rally_unit_number/rally_entity are only
# ever set inside scripts/barracks.lua's spawn(), which calls
# rally_position() — and spawn() never runs with an empty inventory. So the
# "rally path" (now: an O(1) LuaEntity.valid check, plus a bounded
# position+radius re-resolution scan on the rare tick a binding actually
# goes stale) was never exercised by any prior round of this benchmark.
#
# Fix: place 3 tank-squad-rally-flag entities near the 3 barracks, then
# genuinely bind each barracks to its nearest flag by driving spawn() to
# actually run once per barracks — a real call to rally_position(), not a
# manual storage write. (How a finished build is produced changed after this
# comment was written — see the "Stocking" comment below, at the point
# where the build is actually produced.) This intentionally happens BEFORE
# any benchmark soldiers are spawned, so the "training" soldier each
# barracks builds while binding can be swept up by a plain "destroy every
# tank-squad-soldier-*" call with zero risk of also destroying a benchmark
# soldier (none exist yet). Barracks inventories are then emptied again so
# no further spawn happens mid-benchmark, exactly as before.
python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] local n=$COUNT local bx={} if n>0 then bx={n*3*0.25,n*3*0.5,n*3*0.75} else bx={10,20,30} end local placed=0 for _,x in pairs(bx) do local p=s.find_non_colliding_position('tank-squad-barracks',{x=x,y=3},16,1) if p then local b=s.create_entity{name='tank-squad-barracks',position=p,force='player',raise_built=true} if b then placed=placed+1 local fp=s.find_non_colliding_position('tank-squad-rally-flag',{x=p.x+4,y=p.y},16,1) if fp then s.create_entity{name='tank-squad-rally-flag',position=fp,force='player',raise_built=true} end end end end rcon.print('barracks_placed '..placed)"

# Verify storage.barracks was actually populated by the mod (not just that
# create_entity succeeded). RCON's /silent-command runs in the console
# script's OWN empty storage; the __tank-squads__ prefix (same convention
# test/lib.sh's run_case uses) routes the command into the mod's real script
# context so #storage.barracks reflects what barracks.tick() will see.
BARRACKS_REGISTERED=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ rcon.print(storage.barracks and #storage.barracks or 0)")
echo "storage.barracks count (verified over RCON, mod context): $BARRACKS_REGISTERED"
if [ "$BARRACKS_REGISTERED" != "3" ]; then
  echo "FATAL: expected 3 registered barracks, got '$BARRACKS_REGISTERED'" >&2
  exit 1
fi

FLAGS_PLACED=$(python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] rcon.print(#s.find_entities_filtered{name='tank-squad-rally-flag'})")
echo "rally flags placed: $FLAGS_PLACED"
if [ "$FLAGS_PLACED" != "3" ]; then
  echo "FATAL: expected 3 rally flags, got '$FLAGS_PLACED'" >&2
  exit 1
fi

# Stocking: the barracks is an assembling machine with separate input and
# output inventories, not a chest. Skip real crafting (its 10-energy recipe
# takes 600 ticks at speed 1, and test cases only get one RCON call = one
# tick) and instead give each barracks a recipe and drop one finished
# recruit item directly into its output inventory, which is exactly what
# scripts/barracks.lua's deploy loop consumes — one remote 'tick' call then
# spawns and rally-binds all 3 at once.
python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] for _,e in pairs(s.find_entities_filtered{name='tank-squad-barracks'}) do e.set_recipe('tank-squad-train-1') e.get_output_inventory().insert{name='tank-squad-recruit-1',count=1} end rcon.print('barracks stocked for one build')"
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ remote.call('tank-squads','tick')" >/dev/null

BOUND=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local n=0 for _,b in pairs(storage.barracks) do if b.rally_unit_number then n=n+1 end end rcon.print(n)")
echo "barracks with an established rally binding: $BOUND"
if [ "$BOUND" != "3" ]; then
  echo "FATAL: expected 3 barracks with a bound rally flag, got '$BOUND'" >&2
  exit 1
fi

# Sweep up the training soldiers spawned by the binding step above, and empty
# every barracks' output inventory back out so no further spawns happen
# mid-benchmark (no further recruit items were ever placed after the single
# one above, so this is a no-op safety net, not a load-bearing step). This
# does not disturb the rally binding itself — that lives on the barracks' own
# storage record, not on whichever soldier happened to trigger it.
python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] local removed=0 for _,e in pairs(s.find_entities_filtered{name={'tank-squad-soldier-1','tank-squad-soldier-2','tank-squad-soldier-3'}}) do e.destroy() removed=removed+1 end for _,e in pairs(s.find_entities_filtered{name='tank-squad-barracks'}) do e.get_output_inventory().clear() end rcon.print('training soldiers cleared: '..removed)"

python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] for i=1,$COUNT do local p=s.find_non_colliding_position('tank-squad-soldier-1',{x=i*3,y=0},32,1) if p then s.create_entity{name='tank-squad-soldier-1',position=p,force='player'} end end rcon.print('spawned')"

# Fix round 1: damage every spawned soldier to ~25% health (100/400 for a
# tier-1 soldier). heal_nearby() only writes when health < max_health, so an
# undamaged soldier goes quiet after the first sweep; at 20 HP/sweep a
# soldier starting at 100 stays below max for most of a 900-tick window,
# keeping the write path live throughout the benchmark.
DAMAGED=$(python3 "$ROOT/test/rcon.py" "/silent-command local s=game.surfaces[1] local n=0 for _,e in pairs(s.find_entities_filtered{name='tank-squad-soldier-1',force='player'}) do e.health=100 n=n+1 end rcon.print(n)")
echo "damaged $DAMAGED"
if [ "$DAMAGED" != "$COUNT" ]; then
  echo "FATAL: requested $COUNT soldiers but only $DAMAGED exist on the map (find_non_colliding_position likely failed for the rest)" >&2
  exit 1
fi

SAVE="bench-$COUNT"
if [ "$MODE" = "patrol" ]; then
  SAVE="bench-$COUNT-patrol"
  PATROL_RESULT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local selected=remote.call('tank-squads','select',1,{left_top={x=-5,y=-5},right_bottom={x=$COUNT*3+5,y=5}}) if selected==0 then rcon.print('No real test player or selectable soldiers'); return end remote.call('tank-squads','division_assign',1,1,{left_top={x=-5,y=-5},right_bottom={x=$COUNT*3+5,y=5}}) remote.call('tank-squads','patrol_waypoint',1,1,{x=0,y=50}) remote.call('tank-squads','patrol_waypoint',1,1,{x=0,y=-50}) local started=remote.call('tank-squads','patrol_start',1,1) rcon.print(started and 'patrolling' or 'Patrol failed to start')")
  if [ "$PATROL_RESULT" != "patrolling" ]; then
    echo "Cannot benchmark patrol: $PATROL_RESULT" >&2
    exit 1
  fi
fi

if [ "$MODE" = "scout" ]; then
  SAVE="bench-$COUNT-scout"
  SCOUT_RESULT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local selected=remote.call('tank-squads','select',1,{left_top={x=-5,y=-5},right_bottom={x=$COUNT*3+5,y=5}}) if selected==0 then rcon.print('No real test player or selectable soldiers'); return end remote.call('tank-squads','division_assign',1,1,{left_top={x=-5,y=-5},right_bottom={x=$COUNT*3+5,y=5}}) local on=remote.call('tank-squads','scout_set',1,1,true) rcon.print(on and 'scouting' or 'Scout mode failed to start')")
  if [ "$SCOUT_RESULT" != "scouting" ]; then
    echo "Cannot benchmark scouting: $SCOUT_RESULT" >&2
    exit 1
  fi
fi

python3 "$ROOT/test/rcon.py" "/silent-command game.server_save('$SAVE')"
sleep 8
stop_server

nice -n 19 "$FACTORIO" --config "$WORK/config.ini" --mod-directory "$MODS" \
  --benchmark "$WORK/saves/$SAVE.zip" --benchmark-ticks "$TICKS" --benchmark-runs 3 \
  --benchmark-verbose all --benchmark-ignore-paused > "$WORK/bench.out" 2>&1

echo "soldiers=$COUNT mode=${MODE:-idle} ticks=$TICKS"
grep -E "^  avg:" "$WORK/bench.out" | tail -1
H=$(grep -n "^tick,timestamp" "$WORK/bench.out" | head -1 | cut -d: -f1)
awk -F, 'NR==1{for(i=1;i<=NF;i++)h[i]=$i;n=NF;next}{for(i=3;i<=n;i++)s[i]+=$i;c++}END{for(i=3;i<=n;i++)if(h[i]=="scriptUpdate")printf "scriptUpdate avg: %.4f ms\n",s[i]/c/1e6}' <(sed -n "${H},\$p" "$WORK/bench.out")
