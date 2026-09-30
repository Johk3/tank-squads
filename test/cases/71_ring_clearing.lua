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
remote.call('tank-squads', 'engineers_ring_set', 'player', 'count', 1)
remote.call('tank-squads', 'engineers_min_team', 0)
local inside = s.create_entity{name = 'biter-spawner', position = {1030, -1020}, force = 'enemy'}
local outside = s.create_entity{name = 'biter-spawner', position = {1130, -1000}, force = 'enemy'}
local c = s.create_entity{name = 'tank-squad-constructor', position = {1000, -1000}, force = force, raise_built = true}
remote.call('tank-squads', 'engineers_set_autonomous', c.unit_number, true)
local ok, err = pcall(function()
  assert(remote.call('tank-squads', 'engineers_build', c.unit_number) == 0, 'built before the interior was read')
  local info = remote.call('tank-squads', 'engineers_ring_info', 'player', 1)
  assert(info and info.live == 0, 'a segment was planned before the interior was read')
  local clearing
  for _ = 1, 100 do
    remote.call('tank-squads', 'engineers_clearing_tick')
    clearing = storage.engineers.rings[force.index].clearing
    if clearing and clearing.passes > 0 then break end
  end
  assert(clearing and clearing.passes > 0, 'the interior read never finished')
  local nests = {}
  for _, nest in pairs(clearing.nests) do nests[#nests + 1] = nest end
  assert(#nests == 1, #nests .. ' nests found')
  assert(math.abs(nests[1].position.x - 1030) < 2, 'found the nest outside the ring')
  local built = 0
  for _ = 1, 400 do built = built + remote.call('tank-squads', 'engineers_build', c.unit_number) end
  assert(nests[1].blocked and nests[1].blocked > game.tick, 'the nest was not blocked')
  assert(built > 0, 'the ring stayed held by a blocked nest')
end)
for _, e in pairs(s.find_entities_filtered{area = area, type = {'wall', 'gate', 'entity-ghost'}}) do e.destroy() end
if c.valid then c.destroy{raise_destroy = true} end
if inside.valid then inside.destroy() end
if outside.valid then outside.destroy() end
for _, t in pairs(force.find_chart_tags(s, area)) do t.destroy() end
remote.call('tank-squads', 'engineers_ring_reset', 'player')
if storage.engineers then
  storage.engineers.min_team = nil
end
if not ok then error(err) end
return 'PASS: a nest inside a ring is found first; one too strong waits while the ring goes on'
