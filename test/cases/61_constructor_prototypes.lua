local s = game.surfaces[1]
game.forces['player'].technologies['tank-squad-unlock'].researched = true
assert(game.forces['player'].recipes['tank-squad-train-constructor'].enabled, 'research did not enable the constructor recipe')
assert(prototypes.entity['tank-squad-constructor'].get_max_health('normal') == 800, 'constructor health is not 800')
local b = s.create_entity{name = 'tank-squad-barracks', position = {80, 60}, force = 'player', raise_built = true}
b.set_recipe('tank-squad-train-constructor')
assert(b.get_recipe() and b.get_recipe().name == 'tank-squad-train-constructor', 'barracks refused the constructor recipe')
b.get_output_inventory().insert{name = 'tank-squad-recruit-constructor', count = 1}
remote.call('tank-squads', 'tick')
local found = s.find_entities_filtered{name = 'tank-squad-constructor', position = b.position, radius = 20, force = 'player'}
local ok, err = pcall(function()
  assert(#found == 1, 'barracks deployed ' .. #found .. ' constructors')
  assert(b.get_output_inventory().get_item_count('tank-squad-recruit-constructor') == 0, 'recruit stayed in the barracks')
  assert(storage.engineers.constructors[found[1].unit_number], 'deployed constructor not registered')
end)
for _, e in ipairs(found) do e.destroy{raise_destroy = true} end
b.destroy()
if not ok then error(err) end
return 'PASS: barracks deploys a registered constructor'
