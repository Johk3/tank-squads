local names = {
  barracks = "tank-squad-barracks",
  flag = "tank-squad-rally-flag",
  soldier_names = {"tank-squad-soldier-1", "tank-squad-soldier-2", "tank-squad-soldier-3", "tank-squad-siege", "tank-squad-flame"},
  soldier_set = {},
  -- Tanks a chaingunner can become on promotion. They have no recipe, so
  -- they come after the headquarters in unit_names and keep the recruit
  -- indices unchanged.
  promoted_names = {"tank-squad-electric", "tank-squad-nuclear"},
  -- Autonomous rammers. They never join a division and take no orders, so
  -- they stay out of soldier_names, unit_names and recruit_names.
  shredder = "tank-squad-shredder",
  shredder_charging = "tank-squad-shredder-charging",
  shredder_recruit = "tank-squad-recruit-shredder",
  shredder_recipe = "tank-squad-train-shredder",
  headquarters = "tank-squad-headquarters",
  -- Every unit a player can select and command: the armed soldiers above,
  -- then the unarmed headquarters. recruit_names[i] trains unit_names[i].
  unit_names = {},
  unit_set = {},
  recruit_names = {"tank-squad-recruit-1", "tank-squad-recruit-2", "tank-squad-recruit-3", "tank-squad-recruit-siege", "tank-squad-recruit-flame", "tank-squad-recruit-headquarters"},
  recruit_set = {},
  -- Division slots the player can bind. Slot 0 is the ad-hoc drag selection
  -- and is deliberately not in this range.
  max_division = 9,
}

local trainable = #names.soldier_names
for _, name in ipairs(names.promoted_names) do names.soldier_names[#names.soldier_names + 1] = name end
for tier, name in pairs(names.soldier_names) do
  names.soldier_set[name] = tier
end

for i = 1, trainable do names.unit_names[#names.unit_names + 1] = names.soldier_names[i] end
names.unit_names[#names.unit_names + 1] = names.headquarters
for _, name in ipairs(names.promoted_names) do names.unit_names[#names.unit_names + 1] = name end
for tier, name in pairs(names.unit_names) do
  names.unit_set[name] = tier
end

for tier, name in pairs(names.recruit_names) do
  names.recruit_set[name] = tier
end

names.shredder_names = {names.shredder, names.shredder_charging}
names.shredder_set = {}
for _, name in ipairs(names.shredder_names) do names.shredder_set[name] = true end

return names
