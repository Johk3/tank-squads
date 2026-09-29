local t = storage.shredder_stand_down_case
local function current()
  for _, r in pairs(storage.shredders.units) do
    if r.entity.valid and r.entity.surface == t.surface then return r end
  end
end
if not t then
  local s = game.surfaces['shredder-stand-down'] or game.create_surface('shredder-stand-down', {width = 192, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -20, 90 do for y = -30, 30 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['shredder-stand-down'] or game.create_force('shredder-stand-down')
  local shredder = assert(s.create_entity{name = 'tank-squad-shredder', position = {0, 0}, force = f, raise_built = true})
  local only = assert(s.create_entity{name = 'medium-worm-turret', position = {80, 0}, force = 'enemy'})
  only.active = false
  assert(remote.call('tank-squads', 'shredders_strike', {shredder.unit_number}, s.index, {x = 80, y = 0}, f.name, 40) == 1)
  storage.shredder_stand_down_case = {surface = s, only = only, stage = 'charging', started = game.tick}
  return 'WAIT: shredder igniting'
end
local ok, result = pcall(function()
  if t.stage == 'charging' then
    local r = current()
    if not (r and r.state == 'charging') then
      if game.tick - t.started > 120 then error('shredder never charged') end
      return 'WAIT: shredder igniting'
    end
    t.only.destroy{raise_destroy = true}
    t.stage, t.started = 'stand-down', game.tick
    return 'WAIT: shredder standing down'
  end
  local r = current()
  if not (r and r.entity.name == 'tank-squad-shredder') then
    if game.tick - t.started > 120 then error('shredder kept charging with no enemy left') end
    return 'WAIT: shredder standing down'
  end
  assert(r.state == 'parked' or r.state == 'moving', 'stood-down shredder in state ' .. r.state)
  assert(not next(r.renders), 'stood-down shredder kept its drawings')
  return 'stood down with no enemy left'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
if t.only.valid then t.only.destroy{raise_destroy = true} end
for _, e in pairs(t.surface.find_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}) do e.destroy{raise_destroy = true} end
storage.shredder_stand_down_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
