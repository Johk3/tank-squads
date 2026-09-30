local s = game.surfaces[1]
local force = game.forces.player
s.request_to_generate_chunks({-1000, -1000}, 6)
s.force_generate_chunk_requests()
local area = {{-1140, -1140}, {-860, -860}}
for _, e in pairs(s.find_entities_filtered{area = area}) do
  if e.valid and e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = -1140, -861 do for y = -1140, -861 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
remote.call('tank-squads', 'engineers_ring_centre', 'player', 1, -1000, -1000)
remote.call('tank-squads', 'engineers_ring_set', 'player', 'spacing', 100)
remote.call('tank-squads', 'engineers_ring_set', 'player', 'count', 1)
remote.call('tank-squads', 'engineers_min_team', 0)
local c = s.create_entity{name = 'tank-squad-constructor', position = {-910, -1000}, force = force, raise_built = true}
local ok, err = pcall(function()
  assert(remote.call('tank-squads', 'engineers_ring_plan', 'player', 1, 1) == 'placed')
  for _, g in pairs(s.find_entities_filtered{area = area, type = 'entity-ghost'}) do g.revive() end
  local walls = s.count_entities_filtered{area = area, type = {'wall', 'gate'}}
  assert(walls > 500, walls .. ' walls')
  assert(remote.call('tank-squads', 'engineers_ring_delete', 'player', 1), 'delete refused')
  for _ = 1, 6 do remote.call('tank-squads', 'engineers_ring_tick') end
  remote.call('tank-squads', 'engineers_set_autonomous', c.unit_number, true)
  local taken = 0
  for _ = 1, 300 do taken = taken + remote.call('tank-squads', 'engineers_build', c.unit_number) end
  assert(taken == walls, taken .. ' of ' .. walls .. ' walls taken down')
  remote.call('tank-squads', 'engineers_ring_tick')
  local info = remote.call('tank-squads', 'engineers_ring_info', 'player', 1)
  assert(info.state == 'deleted', info.state)
  assert(s.count_entities_filtered{area = area, type = {'wall', 'gate'}} == 0, 'walls left')
end)
for _, e in pairs(s.find_entities_filtered{area = area, type = {'wall', 'gate', 'entity-ghost'}}) do e.destroy() end
if c.valid then c.destroy{raise_destroy = true} end
for _, t in pairs(force.find_chart_tags(s, area)) do t.destroy() end
if storage.engineers then
  if storage.engineers.rings then storage.engineers.rings[force.index] = nil end
  storage.engineers.dismantle, storage.engineers.min_team = nil, nil
end
if not ok then error(err) end
return 'PASS: a deleted ring is taken down by an autonomous constructor'
