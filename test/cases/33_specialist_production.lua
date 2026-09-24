local t = storage.specialist_production_test
if not t then
  local s = game.surfaces['specialist-combat']
  game.forces.player.technologies['tank-squad-unlock'].researched = true
  local barracks = {}
  for i, kind in ipairs({'siege','flame'}) do
    assert(game.forces.player.recipes['tank-squad-train-'..kind].enabled, 'research did not unlock specialist')
    local b = assert(s.create_entity{name='tank-squad-barracks',position={-10,i*10-20},force='player',raise_built=true})
    b.set_recipe('tank-squad-train-'..kind)
    for _, ingredient in pairs(prototypes.recipe['tank-squad-train-'..kind].ingredients) do
      assert(b.insert{name=ingredient.name,count=ingredient.amount} == ingredient.amount)
    end
    b.crafting_progress = 0.999
    barracks[#barracks+1] = b
  end
  storage.specialist_production_test = {barracks=barracks,started=game.tick}
  return 'WAIT: specialist production'
end
if game.tick-t.started < 120 then return 'WAIT: specialist production' end
local s = t.barracks[1].surface
for _, kind in ipairs({'siege','flame'}) do
  local units = s.find_entities_filtered{name='tank-squad-'..kind,force='player'}
  assert(#units == 1, 'barracks did not produce exactly one '..kind)
  assert(storage.weapons[units[1].unit_number], 'deployed specialist has no weapon')
  units[1].destroy{raise_destroy=true}
end
for _, b in ipairs(t.barracks) do
  assert(b.get_output_inventory().is_empty(), 'deployed recruit remains in output')
  b.destroy{raise_destroy=true}
end
storage.specialist_production_test = nil
return 'PASS: both specialists crafted from materials and deployed with guns'
