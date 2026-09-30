local t = storage.tracks_test
if not t then
  local s = game.surfaces['tracks'] or game.create_surface('tracks', {width = 160, height = 160, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 3)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -80, 79 do for y = -80, 79 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  s.always_day = true
  for x = 10, 22 do for y = -80, 79 do s.create_entity{name = 'tree-01', position = {x + 0.5, y + 0.5}} end end
  local rock = s.create_entity{name = 'big-rock', position = {30, 0}}
  for y = -6, 6 do s.create_entity{name = 'stone-wall', position = {40.5, y + 0.5}, force = 'player'} end
  remote.call('tank-squads', 'engineers_min_team', 0)
  local c = s.create_entity{name = 'tank-squad-constructor', position = {-20, 0}, force = 'player', raise_built = true}
  c.commandable.set_command{type = defines.command.go_to_location, destination = {50, 0}, radius = 2,
    distraction = defines.distraction.none}
  game.speed = 20
  storage.tracks_test = {c = c, rock = rock, started = game.tick}
  return 'WAIT: constructor driving into the forest'
end
local c = t.c
local elapsed = game.tick - t.started
if c.valid and c.position.x < 48 and elapsed < 3000 then return 'WAIT: constructor driving into the forest' end
game.speed = 1
storage.engineers.min_team = nil
local s = game.surfaces['tracks']
local x = c.valid and c.position.x or -999
local rock_gone = not t.rock.valid
local walls = s.count_entities_filtered{name = 'stone-wall'}
local stumps = s.count_entities_filtered{type = 'corpse', area = {{9, -10}, {24, 10}}}
local untouched = s.count_entities_filtered{type = 'tree', area = {{9, 30}, {24, 80}}}
for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
storage.tracks_test = nil
if x < 48 then error('constructor stuck at x = ' .. x .. ' after ' .. elapsed .. ' ticks') end
if not rock_gone then error('the rock on the way was left standing') end
if walls ~= 13 then error('a wall was crushed: ' .. walls .. ' of 13 left') end
if stumps == 0 then error('crushed trees left no stumps') end
if untouched ~= 13 * 50 then error('trees away from the tracks fell: ' .. untouched .. ' of ' .. 13 * 50 .. ' left') end
return 'PASS: drove through a forest in ' .. elapsed .. ' ticks, crushing ' .. stumps .. ' trees on its way'
