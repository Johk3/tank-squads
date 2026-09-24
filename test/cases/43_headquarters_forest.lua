local t = storage.forest_test
if not t then
  local s = game.surfaces['hq-forest'] or game.create_surface('hq-forest', {width = 160, height = 160, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 3)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -80, 79 do for y = -80, 79 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  s.always_day = true
  for x = 10, 22, 2 do for y = -80, 79, 2 do s.create_entity{name = 'tree-01', position = {x, y}} end end
  local rock = s.create_entity{name = 'huge-rock', position = {30, 0}}
  local wall = s.create_entity{name = 'stone-wall', position = {16, 30}, force = 'player'}
  local hq = s.create_entity{name = 'tank-squad-headquarters', position = {-20, 0}, force = 'player', raise_built = true}
  remote.call('tank-squads', 'headquarters_tick')
  hq.commandable.set_command{type = defines.command.go_to_location, destination = {50, 0}, radius = 4, distraction = defines.distraction.none}
  game.speed = 20
  storage.forest_test = {hq = hq, rock = rock, wall = wall, started = game.tick}
  return 'WAIT: headquarters driving into the forest'
end
local hq = t.hq
local elapsed = game.tick - t.started
if hq.valid and hq.position.x < 40 and elapsed < 6000 then return 'WAIT: headquarters driving into the forest' end
game.speed = 1
local s = game.surfaces['hq-forest']
local x = hq.valid and hq.position.x or -999
local rock_gone, wall_kept = not t.rock.valid, t.wall.valid
local untouched = s.count_entities_filtered{type = 'tree', area = {{8, 40}, {24, 80}}}
for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
storage.forest_test = nil
if x < 40 then error('headquarters stuck in the forest at x = ' .. x) end
if not rock_gone then error('rock in the way was left standing') end
if not wall_kept then error('a player wall was destroyed') end
if untouched ~= 140 then error('trees away from the path were cleared: ' .. untouched .. ' of 140 left') end
return 'PASS: drove through a forest band in ' .. elapsed .. ' ticks, clearing only its path'
