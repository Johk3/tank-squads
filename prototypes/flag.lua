local util = require("util")

local entity = {
  type = "simple-entity-with-owner",
  name = "tank-squad-rally-flag",
  icon = "__base__/graphics/icons/radar.png",
  flags = {"placeable-player", "player-creation"},
  max_health = 100,
  minable = {mining_time = 0.2, result = "tank-squad-rally-flag"},
  collision_box = {{-0.3, -0.3}, {0.3, 0.3}},
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  picture = {
    filename = "__base__/graphics/icons/radar.png",
    width = 64,
    height = 64,
    scale = 0.5,
  },
}

local item = util.table.deepcopy(data.raw["item"]["radar"])
item.name = "tank-squad-rally-flag"
item.icon = "__base__/graphics/icons/radar.png"
item.place_result = "tank-squad-rally-flag"
item.order = "z-tank-squad-b"
item.subgroup = "defensive-structure"

data:extend{entity, item}
