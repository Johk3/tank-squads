local parked = prototypes.entity['tank-squad-shredder']
local charging = prototypes.entity['tank-squad-shredder-charging']
assert(parked and charging, 'shredder units are missing')
assert(parked.type == 'unit' and charging.type == 'unit', 'shredders bypass native unit AI')
assert(parked.get_max_health('normal') == 600 and charging.get_max_health('normal') == 600, 'wrong shredder health')
assert(math.abs(charging.speed - 1.0) < 1e-6 and math.abs(parked.speed - 0.35) < 1e-6, 'wrong shredder speeds')
assert(charging.attack_parameters.range == 1.5, 'crash range differs')
assert(prototypes.recipe['tank-squad-train-shredder'] and prototypes.item['tank-squad-recruit-shredder'], 'shredder cannot be trained')
local unlocks = false
for _, effect in pairs(prototypes.technology['tank-squad-unlock'].effects) do
  if effect.type == 'unlock-recipe' and effect.recipe == 'tank-squad-train-shredder' then unlocks = true end
end
assert(unlocks, 'research does not unlock the shredder')
for _, name in ipairs({'tank-squad-shredder-fuse', 'tank-squad-shredder-shard', 'tank-squad-shredder-burst', 'tank-squad-shredder-smoke'}) do
  assert(prototypes.entity[name], 'missing ' .. name)
end
local s = game.surfaces[1]
for _, name in ipairs({'tank-squad-shredder-arm', 'tank-squad-shredder-boost', 'tank-squad-shredder-lock', 'tank-squad-shredder-breakup'}) do
  local object = rendering.draw_animation{animation = name, target = {0, 0}, surface = s, time_to_live = 1}
  assert(object.valid, 'animation did not draw: ' .. name)
  object.destroy()
end
for _, name in ipairs({'tank-squad-shredder-lock-sound', 'tank-squad-shredder-boost-sound'}) do
  assert(helpers.is_valid_sound_path(name), 'missing sound ' .. name)
end
return 'PASS: shredder prototypes load'
