local s = game.surfaces[1]
local force = game.forces['player']
s.request_to_generate_chunks({220, 40}, 1)
s.force_generate_chunk_requests()
local area = {{210, 30}, {230, 50}}
for _, e in pairs(s.find_entities_filtered{area = area}) do if e.type ~= 'character' then e.destroy() end end
local cliff = s.create_entity{name = 'cliff', position = {220, 40}, cliff_orientation = 'west-to-east'}
local box = cliff and cliff.bounding_box
local spot = box and {x = math.floor((box.left_top.x + box.right_bottom.x) / 2) + 0.5, y = math.floor((box.left_top.y + box.right_bottom.y) / 2) + 0.5}
local ghost = spot and s.create_entity{name = 'entity-ghost', inner_name = 'stone-wall', position = spot, force = force, raise_built = true}
local c = s.create_entity{name = 'tank-squad-constructor', position = {212, 40}, force = force, raise_built = true}
local ok, err = pcall(function()
  assert(cliff, 'no cliff made')
  assert(ghost, 'no ghost on the cliff')
  local built = remote.call('tank-squads', 'engineers_build', c.unit_number)
  assert(built == 1, 'built ' .. tostring(built) .. ' walls on the cliff')
  assert(not cliff.valid, 'the cliff under the ghost survived')
end)
if c.valid then c.destroy{raise_destroy = true} end
for _, e in pairs(s.find_entities_filtered{area = area}) do if e.type ~= 'character' then e.destroy() end end
if not ok then error(err) end
return 'PASS: a constructor clears a cliff under a wall ghost and builds the wall'
