local names = {
  barracks = "tank-squad-barracks",
  flag = "tank-squad-rally-flag",
  soldier_names = {"tank-squad-soldier-1", "tank-squad-soldier-2", "tank-squad-soldier-3", "tank-squad-siege", "tank-squad-flame"},
  soldier_set = {},
  recruit_names = {"tank-squad-recruit-1", "tank-squad-recruit-2", "tank-squad-recruit-3", "tank-squad-recruit-siege", "tank-squad-recruit-flame"},
  recruit_set = {},
  -- Division slots the player can bind. Slot 0 is the ad-hoc drag selection
  -- and is deliberately not in this range.
  max_division = 9,
}

for tier, name in pairs(names.soldier_names) do
  names.soldier_set[name] = tier
end

for tier, name in pairs(names.recruit_names) do
  names.recruit_set[name] = tier
end

return names
