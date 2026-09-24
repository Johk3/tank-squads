local siege = prototypes.entity['tank-squad-siege']
local flame = prototypes.entity['tank-squad-flame']
assert(siege and flame, 'specialist tanks are missing')
assert(siege.type == 'unit' and flame.type == 'unit', 'specialists bypass native unit AI')
assert(siege.get_max_health('normal') == 900 and flame.get_max_health('normal') == 2400, 'wrong specialist health')
assert(siege.attack_parameters.range == 52 and flame.attack_parameters.range == 10, 'wrong specialist range')
assert(siege.vision_distance == 52, 'siege tank cannot see its own range')
assert(siege.attack_parameters.cooldown == 120, 'wrong cannon cadence')
for _, kind in ipairs({'siege', 'flame'}) do
  local r = prototypes.recipe['tank-squad-train-' .. kind]
  assert(r and r.category == 'tank-squad-training', 'specialist cannot be built at barracks')
  assert(r.products[1].name == 'tank-squad-recruit-' .. kind, 'wrong recruit output')
end
return 'PASS: native specialist stats and barracks recipes'
