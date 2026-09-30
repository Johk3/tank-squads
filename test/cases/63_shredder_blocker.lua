local t = storage.shredder_blocker_case
if not t then
  local s = game.surfaces['shredder-blocker'] or game.create_surface('shredder-blocker', {width = 192, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  --[[ The target nest stands on an island, so no path reaches it. A nest
       beside the shredder is too far from the target for any retarget. ]]
  local tiles = {}
  for x = -20, 90 do
    for y = -30, 30 do
      local d = math.sqrt((x - 80) ^ 2 + y ^ 2)
      tiles[#tiles + 1] = {name = (d > 6 and d < 12) and 'water' or 'grass-1', position = {x, y}}
    end
  end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['shredder-blocker'] or game.create_force('shredder-blocker')
  local function nest(x, y)
    local e = assert(s.create_entity{name = 'biter-spawner', position = {x, y}, force = 'enemy'})
    e.active = false
    return e
  end
  local target, blocker = nest(80, 0), nest(3.2, 0)
  local shredder = assert(s.create_entity{name = 'tank-squad-shredder', position = {0, 0}, force = f, raise_built = true})
  assert(remote.call('tank-squads', 'shredders_strike', {shredder.unit_number}, s.index, {x = 80, y = 0}, f.name, 1) == 1)
  storage.shredder_blocker_case = {surface = s, target = target, blocker = blocker, started = game.tick}
  return 'WAIT: shredder igniting'
end
local ok, result = pcall(function()
  local left = t.surface.count_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}
  if t.blocker.valid and game.tick - t.started < 300 then return 'WAIT: shredder charging' end
  assert(not t.blocker.valid, 'the shredder did not ram the nest beside it when its path failed')
  assert(t.target.valid, 'the shredder reached a nest it has no path to')
  return 'rammed the nest beside it in ' .. (game.tick - t.started) .. ' ticks'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
for _, e in pairs(t.surface.find_entities_filtered{force = 'enemy'}) do e.destroy() end
for _, e in pairs(t.surface.find_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}) do e.destroy{raise_destroy = true} end
storage.shredder_blocker_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
