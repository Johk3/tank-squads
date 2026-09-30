local s = game.surfaces[1]
local force = game.forces.player
s.request_to_generate_chunks({1000, 1000}, 6)
s.force_generate_chunk_requests()
local area = {{860, 860}, {1140, 1140}}
for _, e in pairs(s.find_entities_filtered{area = area}) do
  if e.valid and e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = 860, 1139 do for y = 860, 1139 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
local made = {}
local function add(spec) local e = s.create_entity(spec); made[#made + 1] = e; return e end
add{name = 'tree-01', position = {1100.5, 950.5}}
add{name = 'assembling-machine-1', position = {1101.5, 960.5}, force = force}
for x = 1090, 1110 do add{name = 'transport-belt', position = {x + 0.5, 1030.5}, direction = defines.direction.east, force = force} end
for x = 1087, 1115, 2 do add{name = 'straight-rail', position = {x, 1051}, direction = defines.direction.east, force = force} end
local water = {}
for x = 1096, 1106 do water[#water + 1] = {name = 'water', position = {x, 1070}} end
s.set_tiles(water)
remote.call('tank-squads', 'engineers_ring_centre', 'player', 1, 1000, 1000)
remote.call('tank-squads', 'engineers_ring_set', 'player', 'spacing', 100)
local function ghost_at(x, y)
  local found = s.find_entities_filtered{area = {{x - 0.4, y - 0.4}, {x + 0.4, y + 0.4}}, type = 'entity-ghost'}
  return found[1]
end
local ok, err = pcall(function()
  local result, live = remote.call('tank-squads', 'engineers_ring_plan', 'player', 1, 1)
  assert(result == 'placed', 'segment 1: ' .. tostring(result))
  assert(live > 500, live .. ' ghosts')
  assert(ghost_at(1100.5, 930.5) and ghost_at(1100.5, 930.5).ghost_name == 'stone-wall', 'plain wall missing')
  assert(ghost_at(1100.5, 950.5), 'no ghost on the tree tile')
  local gates = s.count_entities_filtered{area = {{1098, 991}, {1103, 1009}}, ghost_name = 'gate'}
  assert(gates == 16, gates .. ' gatehouse gates')
  assert(not ghost_at(1100.5, 960.5), 'a ghost stands on the assembler')
  assert(ghost_at(1109.5, 960.5), 'no bulge front beyond the assembler')
  for x = 1099, 1101 do assert(not ghost_at(x + 0.5, 1030.5), 'wall across the belt') end
  assert(#force.find_chart_tags(s, {{1090, 1020}, {1110, 1040}}) == 1, 'no open crossing tag')
  assert(ghost_at(1100.5, 1050.5) and ghost_at(1100.5, 1050.5).ghost_name == 'gate', 'no rail gate')
  assert(not ghost_at(1100.5, 1070.5), 'a ghost in water')
  local info = remote.call('tank-squads', 'engineers_ring_info', 'player', 1)
  assert(info.bulges >= 1 and info.crossings == 1, 'bulges ' .. info.bulges .. ', crossings ' .. info.crossings)
end)
for _, g in pairs(s.find_entities_filtered{area = area, type = 'entity-ghost'}) do g.destroy() end
for _, e in ipairs(made) do if e.valid then e.destroy() end end
for _, t in pairs(force.find_chart_tags(s, area)) do t.destroy() end
remote.call('tank-squads', 'engineers_ring_reset', 'player')
if not ok then error(err) end
return 'PASS: a ring segment is planned round a tree, a building, a belt, a rail and water'
