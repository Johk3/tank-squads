local util = require("util")

-- The bunker atlas is eight aligned cells: idle plus three training frames on
-- the top row, four deployment frames on the bottom row. The machine uses the
-- idle cell as its base picture and the training row as its working
-- visualisation, so the engine animates production without any Lua.
local ATLAS = "__tank-squads__/graphics/barracks.png"
local CELL = {width = 384, height = 512, scale = 0.28, shift = {0, -0.2}}

local function cell(x, y, frame_count)
  return {
    filename = ATLAS,
    width = CELL.width, height = CELL.height,
    scale = CELL.scale, shift = CELL.shift,
    x = x, y = y,
    frame_count = frame_count or 1,
    line_length = frame_count or 1,
  }
end

local entity = {
  type = "assembling-machine",
  name = "tank-squad-barracks",
  icon = "__tank-squads__/graphics/barracks-icon.png",
  icon_size = 1254,
  flags = {"placeable-player", "player-creation"},
  minable = {mining_time = 0.5, result = "tank-squad-barracks"},
  max_health = 600,
  collision_box = {{-1.4, -1.4}, {1.4, 1.4}},
  selection_box = {{-1.5, -1.5}, {1.5, 1.5}},
  -- Declared rather than inferred from the collision box, so the footprint
  -- cannot drift if the boxes are ever retuned.
  tile_width = 3,
  tile_height = 3,
  crafting_categories = {"tank-squad-training"},
  crafting_speed = 1,
  -- A void source keeps the 0.2.0 behaviour: a barracks needs materials, not
  -- a power network. energy_usage is still required by the prototype.
  energy_source = {type = "void"},
  energy_usage = "90kW",
  module_slots = 0,
  allowed_effects = {},
  graphics_set = {
    animation = cell(0, 0),
    working_visualisations = {
      {
        animation = cell(CELL.width, 0, 3),
        -- Training frames sit in the same cell as the base picture, so no
        -- extra offset is needed.
        always_draw = false,
      },
    },
  },
}

-- Played by scripts/barracks.lua when a soldier actually walks out. Deployment
-- is an event, not a machine state, so it stays a Lua-driven animation.
local deploy = cell(0, CELL.height, 4)
deploy.type = "animation"
deploy.name = "tank-squad-barracks-deploy"

local category = {type = "recipe-category", name = "tank-squad-training"}

local item = util.table.deepcopy(data.raw["item"]["steel-chest"])
item.name = "tank-squad-barracks"
item.icon = entity.icon
item.icon_size = entity.icon_size
item.icons = nil
item.place_result = "tank-squad-barracks"
item.order = "z-tank-squad-a"
item.subgroup = "storage"

data:extend{category, entity, item, deploy}
