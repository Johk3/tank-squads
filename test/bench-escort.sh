#!/usr/bin/env bash
# Profile escort.tick() with 10 escorts x 10 soldiers (5 defensive, 5
# offensive) on the sandbox test server. Usage: test/bench-escort.sh [sweeps]
#
# The engine --benchmark mode loads a save with no connected players, so a
# ward cannot exist there. This script instead fakes owner and ward players
# inside the mod context (as test/cases/28_escort.lua does) and times the
# escort sweep with LuaProfiler. Engine pathfinding caused by escort orders is
# NOT included.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SWEEPS="${1:-300}"
setup_sandbox
trap stop_server EXIT
start_server || exit 1
# A save's first-ever console command is swallowed by the engine's
# achievement-disabling confirmation prompt; this warm-up call absorbs that
# on a freshly created sandbox map so the real command below always runs.
python3 "$ROOT/test/rcon.py" "/silent-command rcon.print('warmup')" >/dev/null
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local engine_game, engine_rendering = game, rendering local old_divisions, old_index = storage.divisions, storage.unit_divisions local s = game.surfaces[1] s.request_to_generate_chunks({0, 0}, 16) s.force_generate_chunk_requests() for _, e in pairs(s.find_entities_filtered{area = {{-600, -600}, {600, 600}}, force = 'enemy'}) do e.destroy() end storage.divisions, storage.unit_divisions = {}, {} local created = {} local fake, wards = {}, {} local function person(index, name, character) fake[index] = {index = index, name = name, force = engine_game.forces.player, surface = s, connected = true, character = character, print = function() end} end for w = 1, 10 do local c = s.create_entity{name = 'character', position = {w * 60 - 330, 0}, force = 'player'} created[#created + 1] = c wards[w] = c person(900000 + w, 'ward' .. w, c) end person(899999, 'owner-a') person(899998, 'owner-b') game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end}, {__index = function(_, k) return engine_game[k] end}) rendering = {} for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end end for w = 1, 10 do local owner, d = 899999, w if w == 10 then owner, d = 899998, 1 end local x = w * 60 - 330 for i = 1, 10 do created[#created + 1] = s.create_entity{name = 'tank-squad-soldier-1', position = {x + i * 2, 20}, force = 'player'} end remote.call('tank-squads', 'division_assign', owner, d, {left_top = {x = x, y = 15}, right_bottom = {x = x + 25, y = 25}}) remote.call('tank-squads', 'escort_start', owner, d, 900000 + w, w <= 5 and 'defensive' or 'offensive') end for i = 1, 30 do created[#created + 1] = s.create_entity{name = 'small-biter', position = {i * 20 - 300, 110}, force = 'enemy'} end for _ = 1, 5 do remote.call('tank-squads', 'escort_tick') end local p = game.create_profiler() for i = 1, $SWEEPS do if i % 7 == 0 then local c = wards[1 + i % 10] c.teleport({c.position.x + 1, c.position.y}) end remote.call('tank-squads', 'escort_tick') end p.stop() p.divide($SWEEPS) for owner, d in pairs({[899999] = 9, [899998] = 1}) do for n = 1, d do remote.call('tank-squads', 'escort_stop', owner, n) end end for _, e in ipairs(created) do if e.valid then e.destroy() end end game, rendering = engine_game, engine_rendering storage.divisions, storage.unit_divisions = old_divisions, old_index rcon.print({'', 'escort sweep avg (10 escorts, 100 soldiers): ', p})"
