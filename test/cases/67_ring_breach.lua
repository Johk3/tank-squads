local s = game.surfaces[1]
local force = game.forces.player
s.request_to_generate_chunks({1000, -1000}, 6)
s.force_generate_chunk_requests()
local area = {{860, -1140}, {1140, -860}}
for _, e in pairs(s.find_entities_filtered{area = area}) do
  if e.valid and e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = 860, 1139 do for y = -1140, -861 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
remote.call('tank-squads', 'engineers_ring_centre', 'player', 1, 1000, -1000)
remote.call('tank-squads', 'engineers_ring_set', 'player', 'spacing', 100)
local ok, err = pcall(function()
  local result = remote.call('tank-squads', 'engineers_ring_plan', 'player', 1, 1)
  assert(result == 'placed', tostring(result))
  for _, g in pairs(s.find_entities_filtered{area = area, type = 'entity-ghost'}) do g.revive() end
  local wall = s.find_entities_filtered{area = {{1100, -1071}, {1101, -1070}}, name = 'stone-wall'}[1]
  assert(wall, 'no wall at the breach tile')
  wall.die(game.forces.enemy)
  local ghost = s.find_entities_filtered{area = {{1100, -1071}, {1101, -1070}}, type = 'entity-ghost'}[1]
  assert(ghost and ghost.ghost_name == 'stone-wall', 'no ghost after the breach')
  assert(storage.engineers.ring_ghosts[ghost.unit_number], 'the breach ghost is not a ring ghost')
  local info = remote.call('tank-squads', 'engineers_ring_info', 'player', 1)
  assert(info.state == 'building', info.state)
end)
for _, e in pairs(s.find_entities_filtered{area = area, type = {'wall', 'gate', 'entity-ghost'}}) do e.destroy() end
for _, t in pairs(force.find_chart_tags(s, area)) do t.destroy() end
if storage.engineers and storage.engineers.rings then storage.engineers.rings[force.index] = nil end
if not ok then error(err) end
return 'PASS: a ring wall killed by the enemy gets a ring ghost again'
