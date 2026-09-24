data:extend{
  {
    type = "recipe",
    name = "tank-squad-barracks",
    enabled = false,
    energy_required = 2,
    ingredients = {
      {type = "item", name = "steel-plate", amount = 20},
      {type = "item", name = "electronic-circuit", amount = 10},
      {type = "item", name = "iron-gear-wheel", amount = 20},
    },
    results = {{type = "item", name = "tank-squad-barracks", amount = 1}},
  },
  {
    type = "recipe",
    name = "tank-squad-rally-flag",
    enabled = false,
    energy_required = 0.5,
    ingredients = {{type = "item", name = "iron-plate", amount = 5}},
    results = {{type = "item", name = "tank-squad-rally-flag", amount = 1}},
  },
}

local AMMO_BY_TIER = {
  "firearm-magazine",
  "piercing-rounds-magazine",
  "uranium-rounds-magazine",
}

local training = {}
for tier = 1, 3 do
  local recruit = "tank-squad-recruit-" .. tier
  table.insert(training, {
    type = "item",
    name = recruit,
    icon = "__tank-squads__/graphics/chaingun-icon.png",
    icon_size = 1254,
    -- The recruit exists only to carry a finished craft from the engine to
    -- scripts/barracks.lua, which converts it into a soldier entity. It is
    -- never craftable by hand and never shown to the player.
    hidden = true,
    hidden_in_factoriopedia = true,
    stack_size = 1,
    subgroup = "creatures",
    order = "z-tank-squad-recruit-" .. tier,
  })
  table.insert(training, {
    type = "recipe",
    name = "tank-squad-train-" .. tier,
    category = "tank-squad-training",
    enabled = false,
    energy_required = 10,
    ingredients = {
      {type = "item", name = "steel-plate", amount = 15},
      {type = "item", name = "iron-gear-wheel", amount = 20},
      {type = "item", name = AMMO_BY_TIER[tier], amount = 10},
    },
    results = {{type = "item", name = recruit, amount = 1}},
    allow_productivity = false,
    allow_decomposition = false,
  })
end

data:extend(training)

for _, spec in ipairs({
  {kind = 'siege', steel = 40, gears = 30, ammo = 'cannon-shell', time = 30},
  {kind = 'flame', steel = 60, gears = 40, ammo = 'flamethrower-ammo', time = 30},
}) do
  local recruit = 'tank-squad-recruit-' .. spec.kind
  data:extend{
    {type = 'item', name = recruit, icon = '__tank-squads__/graphics/' .. spec.kind .. '-icon.png',
      icon_size = 1254, hidden = true, hidden_in_factoriopedia = true, stack_size = 1,
      subgroup = 'creatures', order = 'z-tank-squad-recruit-' .. spec.kind},
    {type = 'recipe', name = 'tank-squad-train-' .. spec.kind, category = 'tank-squad-training',
      enabled = false, energy_required = spec.time,
      ingredients = {
        {type = 'item', name = 'steel-plate', amount = spec.steel},
        {type = 'item', name = 'iron-gear-wheel', amount = spec.gears},
        {type = 'item', name = spec.ammo, amount = 10},
      },
      results = {{type = 'item', name = recruit, amount = 1}},
      allow_productivity = false, allow_decomposition = false},
  }
end
