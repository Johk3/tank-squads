local s = game.surfaces[1]
local force = game.forces.player
s.request_to_generate_chunks({-1000, 1000}, 6)
s.force_generate_chunk_requests()
local area = {{-1140, 860}, {-860, 1140}}
for _, e in pairs(s.find_entities_filtered{area = area}) do
  if e.valid and e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = -1140, -861 do for y = 860, 1139 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
remote.call('tank-squads', 'engineers_ring_centre', 'player', 1, -1000, 1000)
remote.call('tank-squads', 'engineers_ring_set', 'player', 'spacing', 100)
remote.call('tank-squads', 'engineers_ring_set', 'player', 'count', 1)
remote.call('tank-squads', 'engineers_min_team', 0)
local c = s.create_entity{name = 'tank-squad-constructor', position = {-910, 1000}, force = force, raise_built = true}
remote.call('tank-squads', 'engineers_set_autonomous', c.unit_number, true)
local ok, err = pcall(function()
  local built = 0
  for _ = 1, 400 do built = built + remote.call('tank-squads', 'engineers_build', c.unit_number) end
  local info = remote.call('tank-squads', 'engineers_ring_info', 'player', 1)
  assert(info, 'no ring was started')
  assert(info.built >= 1, 'no segment finished; ' .. built .. ' walls built, ' .. info.live .. ' ghosts left')
  local gates = s.count_entities_filtered{area = {{-902, 991}, {-898, 1009}}, name = 'gate'}
  assert(gates == 16, gates .. ' gates built')
  local constructor = remote.call('tank-squads', 'engineers_constructor', c.unit_number)
  assert(constructor.state == 'seeking', 'state ' .. constructor.state)
end)
for _, e in pairs(s.find_entities_filtered{area = area, type = {'wall', 'gate', 'entity-ghost'}}) do e.destroy() end
if c.valid then c.destroy{raise_destroy = true} end
for _, t in pairs(force.find_chart_tags(s, area)) do t.destroy() end
remote.call('tank-squads', 'engineers_ring_reset', 'player')
if storage.engineers then
  storage.engineers.min_team = nil
end
if not ok then error(err) end
return 'PASS: an autonomous constructor plans and builds the segment next to it'
