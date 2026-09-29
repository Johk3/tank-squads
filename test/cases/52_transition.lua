local c = game.surfaces['transition-case'] or game.create_surface('transition-case', {width = 128, height = 128, autoplace_controls = {}})
c.request_to_generate_chunks({0, 0}, 2)
c.force_generate_chunk_requests()
local tiles = {}
for x = -12, 12 do for y = -12, 12 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
c.set_tiles(tiles)
for _, e in pairs(c.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
local f = game.forces['transition-case'] or game.create_force('transition-case')
local a = assert(c.create_entity{name = 'tank-squad-soldier-2', position = {0, 0}, force = f, raise_built = true})
local old_id = a.unit_number
local ok, result = pcall(function()
  local record = assert(storage.veterans[old_id], 'the carrier has no service record')
  local adjective, noun = record.adjective, record.noun
  remote.call('tank-squads', 'transition_override', 'tank-squad-electric')
  local called, rank = pcall(remote.call, 'tank-squads', 'veteran_add_xp', old_id, 60)
  remote.call('tank-squads', 'transition_override', false)
  if not called then error(rank) end
  assert(rank == 1 and not a.valid, 'carrier was not rebuilt on promotion')
  local found = c.find_entities_filtered{name = 'tank-squad-electric'}
  assert(#found == 1, #found .. ' electric tanks after the rebuild')
  local new = found[1]
  assert(new.force == f and new.health == new.max_health, 'the electric tank lost its force or health share')
  local moved = storage.veterans[new.unit_number]
  assert(moved and moved.adjective == adjective and moved.noun == noun and moved.rank == 1 and moved.kind == 'tank-squad-electric', 'record not kept')
  assert(storage.veterans[old_id] == nil and storage.weapons[old_id] == nil, 'old unit number left behind')
  assert(storage.weapons[new.unit_number] and storage.weapons[new.unit_number].gun.valid, 'new tank has no gun')
  assert(storage.weapons[new.unit_number].rank == 1, 'the gun record lost the rank')
end)
for _, e in pairs(c.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
if not ok then error(result) end
local player = game.players[1]
if not player then return 'PASS: promotion rebuilt a carrier and kept its record; division check needs a player' end
local s = game.surfaces[1]
s.request_to_generate_chunks({2000, 2000}, 1)
s.force_generate_chunk_requests()
tiles = {}
for x = 1990, 2010 do for y = 1990, 2010 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
for _, e in pairs(s.find_entities_filtered{area = {{1990, 1990}, {2010, 2010}}}) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
local p = assert(s.create_entity{name = 'tank-squad-soldier-2', position = {2000, 2000}, force = player.force, raise_built = true})
local b = assert(s.create_entity{name = 'tank-squad-soldier-1', position = {2003, 2000}, force = player.force, raise_built = true})
remote.call('tank-squads', 'division_assign', player.index, 7, {{1995, 1995}, {2005, 2005}})
remote.call('tank-squads', 'transition_override', 'tank-squad-electric')
local rank = remote.call('tank-squads', 'veteran_add_xp', p.unit_number, 60)
remote.call('tank-squads', 'transition_override', false)
assert(rank == 1 and not p.valid, 'division carrier was not rebuilt on promotion')
local new = assert(s.find_entities_filtered{name = 'tank-squad-electric', area = {{1990, 1990}, {2010, 2010}}}[1], 'no electric tank in the division')
assert(remote.call('tank-squads', 'division_size', player.index, 7) == 2, 'division lost a member')
for _, e in ipairs({new, b}) do e.destroy{raise_destroy = true} end
return 'PASS: promotion rebuilt a carrier and kept its record and division'
