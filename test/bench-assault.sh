#!/usr/bin/env bash
# Profile escort.tick() for 10 mixed offensive escorts (1 siege, 1 flame and
# 8 carriers each), each assaulting its own inactive nest (spawner + medium
# worm). The escorts are stacked 150 tiles apart, so every division's
# nearest target is its own nest.
# Usage: test/bench-assault.sh [sweeps] [mixed|carrier]
#
# carrier is the baseline: the same ten divisions with carriers only, so
# every sweep runs a plain offensive leg against the same nests.
#
# Owners and wards are faked inside the mod context, as bench-escort.sh does.
# game.tick is proxied and never advances, so phases change only when the
# script moves soldiers. Three figures:
#   start   - the one sweep that picks the targets and starts all 10 assaults
#   stage   - average sweep while every division walks to its staging arc
#   barrage - average sweep once every soldier stands on its slot
# The carrier baseline reports its start sweep and its average leg sweep.
# Engine pathfinding and combat are not included.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SWEEPS="${1:-300}"
[[ "$SWEEPS" =~ ^[0-9]+$ ]] && (( SWEEPS >= 1 )) || exit 2
COMPOSITION="${2:-mixed}"
[[ "$COMPOSITION" == mixed || "$COMPOSITION" == carrier ]] || exit 2
setup_sandbox
trap stop_server EXIT
start_server || exit 1
python3 "$ROOT/test/rcon.py" "/silent-command rcon.print('warmup')" >/dev/null
# Chunk generation gets its own RCON call: the client times out after 30 s.
python3 "$ROOT/test/rcon.py" "/silent-command local s = game.surfaces[1] for w = 1, 10 do s.request_to_generate_chunks({150, 6000 + (w - 1) * 150}, 6) end s.force_generate_chunk_requests() rcon.print('generated')"
LUA=$(cat <<LUA
local engine_game, engine_rendering = game, rendering
local old_divisions, old_index = storage.divisions, storage.unit_divisions
local s = game.surfaces[1]
local function row(w) return 6000 + (w - 1) * 150 end
for _, e in pairs(s.find_entities_filtered{area = {{-600, row(1) - 600}, {900, row(10) + 600}}, force = 'enemy'}) do e.destroy() end
local tiles = {}
for w = 1, 10 do
  local Y = row(w)
  for _, e in pairs(s.find_entities_filtered{area = {{-20, Y - 40}, {330, Y + 40}}}) do
    if e.valid and e.type ~= 'character' then e.destroy() end
  end
  for x = -20, 330 do for y = Y - 40, Y + 40 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
end
s.set_tiles(tiles)
storage.divisions, storage.unit_divisions = {}, {}
local created, fake, owners = {}, {}, {}
local clock = {tick = engine_game.tick}
local function make(args)
  local e = s.create_entity(args)
  if not e then error('could not create ' .. args.name) end
  created[#created + 1] = e
  return e
end
local function person(index, name, character)
  fake[index] = {index = index, name = name, force = engine_game.forces.player, surface = s, connected = true,
    character = character, print = function() end}
end
person(899999, 'owner-a')
person(899998, 'owner-b')
game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
  {__index = function(_, k) if k == 'tick' then return clock.tick end return engine_game[k] end})
rendering = {}
for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
  rendering[method] = function(args) args.players = nil return engine_rendering[method](args) end
end
local ok, err = pcall(function()
  for w = 1, 10 do
    local wx, Y = 0, row(w)
    person(900000 + w, 'ward' .. w, make{name = 'character', position = {wx, Y}, force = 'player'})
    make{name = 'biter-spawner', position = {wx + 300, Y}, force = 'enemy'}.active = false
    make{name = 'medium-worm-turret', position = {wx + 290, Y + 6}, force = 'enemy'}.active = false
    local owner, d = 899999, w
    if w == 10 then owner, d = 899998, 1 end
    owners[w] = {owner, d}
    local kinds = '$COMPOSITION' == 'mixed' and {'tank-squad-siege', 'tank-squad-flame'} or {}
    for i = 1, 10 do make{name = kinds[i] or 'tank-squad-soldier-1', position = {wx + i * 3, Y + 20}, force = 'player'} end
    remote.call('tank-squads', 'division_assign', owner, d, {left_top = {x = wx, y = Y + 15}, right_bottom = {x = wx + 35, y = Y + 25}})
    if not remote.call('tank-squads', 'escort_start', owner, d, 900000 + w, 'offensive') then error('escort ' .. w .. ' rejected') end
  end
  for _ = 1, 4 do remote.call('tank-squads', 'escort_tick') end
  local p_start = game.create_profiler()
  remote.call('tank-squads', 'escort_tick')
  p_start.stop()
  local function phases(want)
    local n = 0
    for _, o in ipairs(owners) do
      local a = storage.divisions[o[1]].slots[o[2]].escort.assault
      if a and a.phase == want then n = n + 1 end
    end
    return n
  end
  if '$COMPOSITION' == 'carrier' then
    if phases('stage') ~= 0 then error('carrier-only divisions started assaults') end
    local p_leg = game.create_profiler()
    for _ = 1, $SWEEPS do remote.call('tank-squads', 'escort_tick') end
    p_leg.stop()
    p_leg.divide($SWEEPS)
    for _, o in ipairs(owners) do remote.call('tank-squads', 'escort_stop', o[1], o[2]) end
    rcon.print({'', 'start sweep (10 plain legs): ', p_start, '\nleg sweep avg: ', p_leg})
    return
  end
  if phases('stage') ~= 10 then error('only ' .. phases('stage') .. ' assaults staged') end
  local p_stage = game.create_profiler()
  for _ = 1, $SWEEPS do remote.call('tank-squads', 'escort_tick') end
  p_stage.stop()
  p_stage.divide($SWEEPS)
  for _, o in ipairs(owners) do
    local a = storage.divisions[o[1]].slots[o[2]].escort.assault
    for unit, slot in pairs(a.slots) do game.get_entity_by_unit_number(unit).teleport(slot) end
  end
  remote.call('tank-squads', 'escort_tick')
  if phases('barrage') ~= 10 then error('only ' .. phases('barrage') .. ' barrages') end
  local p_barrage = game.create_profiler()
  for _ = 1, $SWEEPS do remote.call('tank-squads', 'escort_tick') end
  p_barrage.stop()
  p_barrage.divide($SWEEPS)
  for _, o in ipairs(owners) do remote.call('tank-squads', 'escort_stop', o[1], o[2]) end
  rcon.print({'', 'start sweep (10 assaults): ', p_start, '\nstage sweep avg: ', p_stage, '\nbarrage sweep avg: ', p_barrage})
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions = old_divisions, old_index
if not ok then rcon.print('FAIL: ' .. tostring(err)) end
LUA
)
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ $LUA"
