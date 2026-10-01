local t = storage.make_way_test
if not t then
  local s = game.surfaces['makeway'] or game.create_surface('makeway', {width = 96, height = 96, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 2)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -48, 47 do for y = -48, 47 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  s.always_day = true
  for x = 20, 23 do
    s.create_entity{name = 'entity-ghost', inner_name = 'stone-wall', position = {x + 0.5, 0.5}, force = 'player',
      raise_built = true}
  end
  local soldier = s.create_entity{name = 'tank-squad-soldier-1', position = {21.5, 0.5}, force = 'player'}
  soldier.commandable.set_command{type = defines.command.stop, distraction = defines.distraction.none}
  remote.call('tank-squads', 'engineers_min_team', 0)
  local c = s.create_entity{name = 'tank-squad-constructor', position = {0, 0}, force = 'player', raise_built = true}
  storage.engineers.constructors[c.unit_number].draft_tick = game.tick + 10 ^ 6
  game.speed = 10
  storage.make_way_test = {c = c, soldier = soldier, started = game.tick}
  return 'WAIT: constructor building around a soldier'
end
local s = game.surfaces['makeway']
local walls = s.count_entities_filtered{name = 'stone-wall'}
local elapsed = game.tick - t.started
if walls < 4 and elapsed < 1800 then return 'WAIT: constructor building around a soldier' end
game.speed = 1
storage.engineers.min_team = nil
local soldier = t.soldier
local moved = soldier.valid and math.abs(soldier.position.x - 21.5) + math.abs(soldier.position.y - 0.5) > 1
for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
storage.make_way_test = nil
if walls < 4 then error(walls .. ' of 4 walls after ' .. elapsed .. ' ticks') end
if not moved then error('the soldier stayed on the wall line') end
return 'PASS: the soldier on the wall line made way; 4 walls in ' .. elapsed .. ' ticks'
