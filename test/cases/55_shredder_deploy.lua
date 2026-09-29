local s = game.surfaces[1]
game.forces['player'].technologies['tank-squad-unlock'].researched = true
assert(game.forces['player'].recipes['tank-squad-train-shredder'].enabled, 'research did not enable the shredder recipe')
local b = s.create_entity{name = 'tank-squad-barracks', position = {60, 60}, force = 'player', raise_built = true}
b.set_recipe('tank-squad-train-shredder')
assert(b.get_recipe() and b.get_recipe().name == 'tank-squad-train-shredder', 'barracks refused the shredder recipe')
b.get_output_inventory().insert{name = 'tank-squad-recruit-shredder', count = 1}
remote.call('tank-squads', 'tick')
local found = s.find_entities_filtered{name = 'tank-squad-shredder', position = b.position, radius = 20, force = 'player'}
local ok, err = pcall(function()
  assert(#found == 1, 'barracks deployed ' .. #found .. ' shredders')
  assert(b.get_output_inventory().get_item_count('tank-squad-recruit-shredder') == 0, 'recruit stayed in the barracks')
  assert(storage.shredders.units[found[1].unit_number], 'deployed shredder not registered')
end)
for _, e in ipairs(found) do e.destroy{raise_destroy = true} end
b.destroy()
if not ok then error(err) end
return 'PASS: barracks deploys a registered shredder'
