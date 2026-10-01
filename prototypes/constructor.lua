-- Constructor: an unmanned wall-laying vehicle a barracks trains. Native
-- pathfinding moves it; scripts/engineers/crane.lua draws the crane and
-- places the walls. Its attack is a placeholder the engine never uses, as
-- every command it gets ignores enemies.
local copy = require('util').table.deepcopy
local appearance = require('scripts.appearance')
local names = require('scripts.names')
local look = appearance.constructor

-- Literal paths, so test/check-local-assets.py finds every sheet.
local CHASSIS = '__tank-squads__/graphics/construction-chassis.png'
local ARM = '__tank-squads__/graphics/construction-arm.png'
local ICON = '__tank-squads__/graphics/construction-icon.png'

-- Clockwise from north in 22.5-degree steps, one frame per heading.
local function hull()
  return {filename = CHASSIS, width = 313, height = 313, line_length = 4,
    direction_count = 16, frame_count = 1, scale = look.chassis_scale, apply_projection = false}
end

local unit = copy(data.raw.unit['tank-squad-soldier-1'])
unit.name, unit.icon, unit.icon_size = names.constructor, ICON, 128
unit.order = 'z-' .. names.constructor
unit.max_health, unit.movement_speed = 800, 0.10
unit.distance_per_frame = 0.2
-- The hull is drawn larger than it collides, so it still fits through
-- 2-tile gaps, ring gates and the stand-off beside a ring's band.
unit.collision_box = {{-0.9, -0.9}, {0.9, 0.9}}
unit.selection_box = {{-1.6, -1.6}, {1.6, 1.6}}
unit.run_animation = hull()
unit.attack_parameters = {
  type = 'projectile', range = 0.5, cooldown = 600, ammo_category = 'melee',
  animation = hull(),
  ammo_type = {target_type = 'entity', action = {type = 'direct', action_delivery = {type = 'instant'}}},
}
unit.resistances = nil

data:extend{
  unit,
  -- Hold, extend, release, retract: one cycle per second.
  {type = 'animation', name = names.constructor_crane, filename = ARM, width = 251, height = 251,
    frame_count = 4, line_length = 2, scale = look.crane_scale},
  {type = 'item', name = names.constructor_recruit, icon = ICON, icon_size = 128, hidden = true,
    hidden_in_factoriopedia = true, stack_size = 1, subgroup = 'creatures', order = 'z-tank-squad-recruit-constructor'},
  {type = 'recipe', name = names.constructor_recipe, category = 'tank-squad-training', enabled = false,
    energy_required = 30,
    ingredients = {
      {type = 'item', name = 'steel-plate', amount = 40},
      {type = 'item', name = 'engine-unit', amount = 10},
      {type = 'item', name = 'stone-brick', amount = 100},
    },
    results = {{type = 'item', name = names.constructor_recruit, amount = 1}},
    allow_productivity = false, allow_decomposition = false},
}
