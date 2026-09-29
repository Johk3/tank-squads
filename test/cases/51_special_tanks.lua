local electric = prototypes.entity['tank-squad-electric']
local nuclear = prototypes.entity['tank-squad-nuclear']
assert(electric and nuclear, 'special tanks are missing')
assert(electric.type == 'unit' and nuclear.type == 'unit', 'special tanks bypass native unit AI')
assert(electric.get_max_health('normal') == 1400 and nuclear.get_max_health('normal') == 1600, 'wrong special tank health')
assert(electric.attack_parameters.range == 24 and nuclear.attack_parameters.range == 52, 'wrong special tank range')
assert(prototypes.recipe['tank-squad-train-electric'] == nil and prototypes.recipe['tank-squad-train-nuclear'] == nil, 'special tanks can be trained')
for _, name in ipairs({'tank-squad-electric-ball', 'tank-squad-atomic-rocket', 'tank-squad-nuke-fallback', 'tank-squad-electric-impact', 'tank-squad-electric-shock', 'tank-squad-nuke-detonation'}) do
  assert(prototypes.entity[name], 'missing ' .. name)
end
local s = game.surfaces[1]
for _, name in ipairs({'tank-squad-red-gun', 'tank-squad-green-gun', 'tank-squad-electric-gun', 'tank-squad-nuclear-gun', 'tank-squad-electric-link'}) do
  local object = rendering.draw_animation{animation = name, target = {0, 0}, surface = s, time_to_live = 1}
  assert(object.valid, 'animation did not draw: ' .. name)
  object.destroy()
end
return 'PASS: special tank prototypes, effects and gun animations load'
