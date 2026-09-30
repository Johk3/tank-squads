local s = game.surfaces[1]
game.forces['player'].technologies['tank-squad-unlock'].researched = true
local b = s.create_entity{name = 'tank-squad-barracks', position = {60, -60}, force = 'player', raise_built = true}
b.set_recipe('tank-squad-train-shredder')
local record
for _, entry in ipairs(storage.barracks) do if entry.entity == b then record = entry end end
local found = {}
local ok, err = pcall(function()
  assert(record, 'barracks not registered')
  record.shredder_limit, record.shredders = 1, {}
  b.get_output_inventory().insert{name = 'tank-squad-recruit-shredder', count = 1}
  remote.call('tank-squads', 'tick')
  b.get_output_inventory().insert{name = 'tank-squad-recruit-shredder', count = 1}
  remote.call('tank-squads', 'tick')
  found = s.find_entities_filtered{name = 'tank-squad-shredder', position = b.position, radius = 20, force = 'player'}
  assert(#found == 1, 'barracks deployed ' .. #found .. ' shredders over a limit of 1')
  assert(b.get_output_inventory().get_item_count('tank-squad-recruit-shredder') == 1, 'the recruit over the limit left')
  assert(not b.active, 'a barracks at its shredder limit kept training')
  found[1].destroy{raise_destroy = true}
  remote.call('tank-squads', 'tick')
  found = s.find_entities_filtered{name = 'tank-squad-shredder', position = b.position, radius = 20, force = 'player'}
  assert(#found == 1, 'the lost shredder was not replaced')
  assert(b.get_output_inventory().get_item_count('tank-squad-recruit-shredder') == 0, 'the waiting recruit stayed')
end)
for _, e in ipairs(found) do if e.valid then e.destroy{raise_destroy = true} end end
b.destroy()
if not ok then error(err) end
return 'PASS: a barracks keeps its shredder limit'
