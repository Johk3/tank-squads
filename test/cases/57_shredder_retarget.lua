local t = storage.shredder_retarget_case
local function current()
  for _, r in pairs(storage.shredders.units) do
    if r.entity.valid and r.entity.surface == t.surface then return r end
  end
end
if not t then
  local s = game.surfaces['shredder-retarget'] or game.create_surface('shredder-retarget', {width = 192, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -20, 90 do for y = -30, 30 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['shredder-retarget'] or game.create_force('shredder-retarget')
  local shredder = assert(s.create_entity{name = 'tank-squad-shredder', position = {0, 0}, force = f, raise_built = true})
  local first = assert(s.create_entity{name = 'big-worm-turret', position = {80, 0}, force = 'enemy'})
  first.active = false
  local second = assert(s.create_entity{name = 'small-worm-turret', position = {80, 14}, force = 'enemy'})
  second.active = false
  assert(remote.call('tank-squads', 'shredders_strike', {shredder.unit_number}, s.index, {x = 80, y = 0}, f.name, 40) == 1)
  storage.shredder_retarget_case = {surface = s, first = first, second = second, stage = 'charging', started = game.tick}
  return 'WAIT: shredder igniting'
end
local ok, result = pcall(function()
  if t.stage == 'charging' then
    local r = current()
    if not (r and r.state == 'charging') then
      if game.tick - t.started > 120 then error('shredder never charged') end
      return 'WAIT: shredder igniting'
    end
    assert(r.target == t.first, 'the strongest worm was not the first target')
    t.first.die()
    t.stage, t.started = 'retarget', game.tick
    return 'WAIT: shredder retargeting'
  end
  local left = t.surface.count_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}
  if (t.second.valid or left > 0) and game.tick - t.started < 300 then return 'WAIT: shredder retargeting' end
  assert(not t.second.valid, 'the shredder did not retarget onto the second worm')
  assert(left == 0, 'the shredder survived its crash')
  return 'retargeted after its first target died'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
for _, key in ipairs({'first', 'second'}) do local e = t[key]; if e and e.valid then e.destroy{raise_destroy = true} end end
for _, e in pairs(t.surface.find_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}) do e.destroy{raise_destroy = true} end
storage.shredder_retarget_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
