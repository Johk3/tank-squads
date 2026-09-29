local player = game.players[1]
if not player then return 'SKIP: needs a player to own a division' end
local s = game.surfaces[1]
s.request_to_generate_chunks({2000, 2000}, 1)
s.force_generate_chunk_requests()
local tiles = {}
for x = 1990, 2010 do for y = 1990, 2010 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
for _, e in pairs(s.find_entities_filtered{area = {{1990, 1990}, {2010, 2010}}}) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
local a = assert(s.create_entity{name = 'tank-squad-soldier-2', position = {2000, 2000}, force = player.force, raise_built = true})
local b = assert(s.create_entity{name = 'tank-squad-soldier-1', position = {2003, 2000}, force = player.force, raise_built = true})
remote.call('tank-squads', 'division_assign', player.index, 7, {{1995, 1995}, {2005, 2005}})
local old_id = a.unit_number
local record = storage.veterans[old_id]
local adjective, noun = record.adjective, record.noun
remote.call('tank-squads', 'transition_override', 'tank-squad-electric')
local rank = remote.call('tank-squads', 'veteran_add_xp', old_id, 60)
remote.call('tank-squads', 'transition_override', false)
assert(rank == 1 and not a.valid, 'carrier was not rebuilt on promotion')
local new = assert(s.find_entities_filtered{name = 'tank-squad-electric', area = {{1990, 1990}, {2010, 2010}}}[1], 'no electric tank')
local moved = storage.veterans[new.unit_number]
assert(moved and moved.adjective == adjective and moved.noun == noun and moved.rank == 1 and moved.kind == 'tank-squad-electric', 'record not kept')
assert(storage.veterans[old_id] == nil and storage.weapons[old_id] == nil, 'old unit number left behind')
assert(storage.weapons[new.unit_number] and storage.weapons[new.unit_number].gun.valid, 'new tank has no gun')
assert(remote.call('tank-squads', 'division_size', player.index, 7) == 2, 'division lost a member')
for _, e in ipairs({new, b}) do e.destroy{raise_destroy = true} end
return 'PASS: promotion rebuilt a carrier and kept its record and division'
