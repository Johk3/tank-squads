local s = game.surfaces[1]
local force = game.forces['player']
s.request_to_generate_chunks({120, 40}, 1)
s.force_generate_chunk_requests()
local made = {}
for x = 0, 3 do
  made[#made + 1] = s.create_entity{name = 'entity-ghost', inner_name = 'stone-wall', position = {120 + x, 40}, force = force, raise_built = true}
end
local tree = s.create_entity{name = 'tree-01', position = {122, 40}}
local c = s.create_entity{name = 'tank-squad-constructor', position = {114, 40}, force = force, raise_built = true}
local area = {{119, 39}, {125, 41}}
local ok, err = pcall(function()
  assert(storage.engineers.constructors[c.unit_number], 'constructor not registered')
  local built = remote.call('tank-squads', 'engineers_build', c.unit_number)
  assert(built == 4, 'built ' .. tostring(built) .. ' walls')
  assert(#s.find_entities_filtered{name = 'stone-wall', area = area} == 4, 'walls missing')
  assert(not (tree and tree.valid), 'a tree on a ghost survived')
  assert(#s.find_entities_filtered{type = 'entity-ghost', area = area} == 0, 'ghosts left')
  local info = remote.call('tank-squads', 'engineers_constructor', c.unit_number)
  assert(info and info.state == 'seeking', 'constructor did not look for more work')
end)
for _, w in pairs(s.find_entities_filtered{name = 'stone-wall', area = area}) do w.destroy() end
for _, g in ipairs(made) do if g.valid then g.destroy() end end
if c.valid then c.destroy{raise_destroy = true} end
if not ok then error(err) end
return 'PASS: a constructor builds a wall line and clears the tree on it'
