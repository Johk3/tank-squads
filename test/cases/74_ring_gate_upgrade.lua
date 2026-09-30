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
remote.call('tank-squads', 'engineers_ring_centre', 'player', 1, 1000, 1000)
remote.call('tank-squads', 'engineers_ring_set', 'player', 'spacing', 100)
local function gates(filter)
  filter.area = {{1098, 991}, {1103, 1009}}
  return s.find_entities_filtered(filter)
end
local ok, err = pcall(function()
  local result = remote.call('tank-squads', 'engineers_ring_plan', 'player', 1, 1)
  assert(result == 'placed', 'segment 1: ' .. tostring(result))
  local ghosts = gates{ghost_name = 'gate'}
  assert(#ghosts == 48, #ghosts .. ' gatehouse gates')
  for _, g in ipairs(ghosts) do
    assert(g.direction == defines.direction.north, 'a gate ghost in a north-south wall faces ' .. g.direction)
  end
  local middle = {}
  for _, g in ipairs(ghosts) do
    if g.position.x == 1100.5 then middle[#middle + 1] = g else g.destroy() end
  end
  assert(#middle == 16, #middle .. ' gates in the middle row')
  for k = 1, 8 do middle[k].direction = defines.direction.east end
  local p = middle[9].position
  middle[9].destroy()
  s.create_entity{name = 'gate', position = p, direction = defines.direction.east, force = force}
  local fixed = remote.call('tank-squads', 'engineers_ring_fix_gates', 'player')
  assert(fixed.turned == 9, fixed.turned .. ' gates turned')
  assert(fixed.added == 32, fixed.added .. ' gate ghosts added')
  local all = gates{ghost_name = 'gate'}
  assert(#all == 47, #all .. ' gate ghosts after the upgrade')
  for _, g in ipairs(all) do
    assert(g.direction == defines.direction.north, 'a gate ghost still faces ' .. g.direction)
  end
  local built = gates{name = 'gate'}
  assert(#built == 1 and built[1].direction == defines.direction.north, 'the built gate was not turned')
  local again = remote.call('tank-squads', 'engineers_ring_fix_gates', 'player')
  assert(again.turned == 0 and again.added == 0, 'second upgrade turned ' .. again.turned .. ', added ' .. again.added)
end)
for _, e in pairs(s.find_entities_filtered{area = area}) do
  if e.valid and e.type ~= 'character' then e.destroy() end
end
remote.call('tank-squads', 'engineers_ring_reset', 'player')
if not ok then error(err) end
return 'PASS: ring gates stand three rows deep along the wall line, and older gates are turned and widened'
