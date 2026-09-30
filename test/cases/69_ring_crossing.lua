local s = game.surfaces[1]
local force = game.forces.player
local area = {{2860, -140}, {3140, 140}}
local function cleanup()
  for _, e in pairs(s.find_entities_filtered{area = area, type = {'wall', 'gate', 'entity-ghost', 'unit'}}) do e.destroy() end
  for _, t in pairs(force.find_chart_tags(s, area)) do t.destroy() end
  if storage.engineers and storage.engineers.rings then storage.engineers.rings[force.index] = nil end
  storage.case69 = nil
  game.speed = 1
end
if not storage.case69 then
  s.request_to_generate_chunks({3000, 0}, 6)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = area}) do
    if e.valid and e.type ~= 'character' then e.destroy() end
  end
  local tiles = {}
  for x = 2860, 3139 do for y = -140, 139 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  remote.call('tank-squads', 'engineers_ring_centre', 'player', 1, 3000, 0)
  remote.call('tank-squads', 'engineers_ring_set', 'player', 'spacing', 100)
  assert(remote.call('tank-squads', 'engineers_ring_plan', 'player', 1, 1) == 'placed')
  for _, g in pairs(s.find_entities_filtered{area = area, type = 'entity-ghost'}) do g.revive() end
  for _ = 1, 40 do remote.call('tank-squads', 'engineers_ring_tick') end
  local soldier = s.create_entity{name = 'tank-squad-soldier-1', position = {3080.5, 0.5}, force = force}
  storage.case69 = {soldier = soldier, tick = game.tick}
  remote.call('tank-squads', 'engineers_go', soldier.unit_number, 3125.5, 0.5)
  local phase = remote.call('tank-squads', 'engineers_crossing', soldier.unit_number)
  if phase ~= 'approach' then cleanup(); error('no crossing started: ' .. tostring(phase)) end
  game.speed = 4
  return 'WAIT: crossing'
end
local soldier = storage.case69.soldier
if not soldier.valid then cleanup(); error('the soldier died') end
if soldier.position.x < 3115 then
  if game.tick - storage.case69.tick > 3600 then
    local x = soldier.position.x
    cleanup()
    error('stuck at x = ' .. x)
  end
  return 'WAIT: crossing'
end
cleanup()
return 'PASS: a soldier crosses a finished ring through its gatehouse'
