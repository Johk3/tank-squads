local t = storage.shredder_water_case
if not t then
  local s = game.surfaces['shredder-water'] or game.create_surface('shredder-water', {width = 192, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  --[[ The target nest stands on an island in a lake, behind a wall of
       cliffs. A parked shredder finds no path there; a charge flies over
       both and rams it. ]]
  local tiles = {}
  for x = -20, 90 do
    for y = -30, 30 do
      local d = math.sqrt((x - 70) ^ 2 + y ^ 2)
      tiles[#tiles + 1] = {name = (d > 5 and d < 16) and 'deepwater' or 'grass-1', position = {x, y}}
    end
  end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  for y = -28, 28, 4 do
    assert(s.create_entity{name = 'cliff', position = {30, y}, cliff_orientation = 'north-to-south'}, 'no cliff')
  end
  local f = game.forces['shredder-water'] or game.create_force('shredder-water')
  local target = assert(s.create_entity{name = 'biter-spawner', position = {70, 0}, force = 'enemy'})
  target.active = false
  local shredder = assert(s.create_entity{name = 'tank-squad-shredder', position = {0, 0}, force = f, raise_built = true})
  assert(remote.call('tank-squads', 'shredders_strike', {shredder.unit_number}, s.index, {x = 70, y = 0}, f.name, 10) == 1)
  storage.shredder_water_case = {surface = s, target = target, started = game.tick}
  return 'WAIT: shredder igniting'
end
local ok, result = pcall(function()
  if t.target.valid and t.target.health >= t.target.max_health and game.tick - t.started < 600 then
    return 'WAIT: shredder charging'
  end
  assert(not t.target.valid or t.target.health < t.target.max_health,
    'the charge never crossed the cliffs and the water to the nest')
  return 'rammed the nest across cliffs and water in ' .. (game.tick - t.started) .. ' ticks'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
for _, e in pairs(t.surface.find_entities_filtered{force = 'enemy'}) do e.destroy() end
for _, e in pairs(t.surface.find_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}) do e.destroy{raise_destroy = true} end
storage.shredder_water_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
