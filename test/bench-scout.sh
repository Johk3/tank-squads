#!/usr/bin/env bash
# Profile scout.tick() for one scouting division on the sandbox test server.
# Usage: test/bench-scout.sh [count] [sweeps] [mix] [aid]
#   count  : soldiers in the division (default 200)
#   sweeps : sweeps timed (default 300)
#   mix    : "carrier" (default) or "mixed" (60% carriers, 20% siege, 20% flame)
#   aid    : "aid" lowers team 1 to 70% health on odd sweeps and restores it on
#            even ones, outside the timed part, so a call for help and its
#            helper stay open for the whole run
#
# The engine --benchmark mode loads a save with no connected players, so no
# division can scout there. This script instead fakes the owning player
# inside the mod context (as test/bench-escort.sh does) and times the scout
# sweep with LuaProfiler. game.tick is proxied and advances one second of
# ticks per sweep, so charting, searches, hop timeouts and failure expiry
# follow the same clock as a real game. Soldiers do not move between sweeps,
# and engine pathfinding caused by scout orders is NOT included.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
COUNT="${1:-200}"
SWEEPS="${2:-300}"
MIX="${3:-carrier}"
AID="${4:-}"
setup_sandbox
trap stop_server EXIT
start_server || exit 1
# A save's first-ever console command is swallowed by the engine's
# achievement-disabling confirmation prompt; this warm-up call absorbs that
# on a freshly created sandbox map so the real command below always runs.
python3 "$ROOT/test/rcon.py" "/silent-command rcon.print('warmup')" >/dev/null
python3 "$ROOT/test/rcon.py" "/silent-command local s = game.surfaces[1] s.request_to_generate_chunks({$COUNT * 1.5, 0}, math.ceil($COUNT * 1.5 / 32) + 4) s.force_generate_chunk_requests() rcon.print('chunks generated')"
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local engine_game, engine_rendering = game, rendering local old_divisions, old_index = storage.divisions, storage.unit_divisions local s = game.surfaces[1] for _, e in pairs(s.find_entities_filtered{name = {'tank-squad-soldier-1', 'tank-squad-siege', 'tank-squad-flame'}}) do e.destroy() end storage.divisions, storage.unit_divisions = {}, {} local owner = 899997 local fake = {[owner] = {index = owner, name = 'scout-owner', force = engine_game.forces.player, surface = s, connected = true, print = function() end}} local tick = engine_game.tick game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end}, {__index = function(_, k) if k == 'tick' then return tick end return engine_game[k] end}) rendering = {} for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end end local created = {} local mixed = '$MIX' == 'mixed' for i = 1, $COUNT do local name = 'tank-squad-soldier-1' if mixed and i % 5 == 4 then name = 'tank-squad-siege' elseif mixed and i % 5 == 0 then name = 'tank-squad-flame' end local p = s.find_non_colliding_position(name, {x = i * 3, y = 0}, 32, 1) if p then created[#created + 1] = s.create_entity{name = name, position = p, force = 'player'} end end remote.call('tank-squads', 'division_assign', owner, 1, {left_top = {x = -5, y = -40}, right_bottom = {x = $COUNT * 3 + 5, y = 40}}) local size = remote.call('tank-squads', 'division_size', owner, 1) remote.call('tank-squads', 'scout_set', owner, 1, true) for _ = 1, 3 do tick = tick + 60 remote.call('tank-squads', 'scout_tick') end local hurt = {} if '$AID' == 'aid' then local st = storage.divisions[owner].slots[1].scout for _, unit in ipairs(st.teams[1].members) do hurt[#hurt + 1] = engine_game.get_entity_by_unit_number(unit) end end local p = game.create_profiler() for i = 1, $SWEEPS do if hurt[1] then p.stop() for _, e in ipairs(hurt) do if e.valid then e.health = e.max_health * (i % 2 == 1 and 0.7 or 1) end end p.restart() end tick = tick + 60 remote.call('tank-squads', 'scout_tick') end p.stop() p.divide($SWEEPS) remote.call('tank-squads', 'scout_set', owner, 1, false) for _, e in ipairs(created) do if e.valid then e.destroy() end end game, rendering = engine_game, engine_rendering storage.divisions, storage.unit_divisions = old_divisions, old_index rcon.print({'', 'scout sweep avg ($MIX $AID, ', size, ' soldiers): ', p})"
