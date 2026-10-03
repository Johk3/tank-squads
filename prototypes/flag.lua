local util = require("util")

local entity = {
  type = "simple-entity-with-owner",
  name = "tank-squad-rally-flag",
  icon = "__tank-squads__/graphics/command-icons/rally.png",
  icon_size = 128,
  flags = {"placeable-player", "player-creation"},
  max_health = 100,
  minable = {mining_time = 0.2, result = "tank-squad-rally-flag"},
  collision_box = {{-0.3, -0.3}, {0.3, 0.3}},
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  picture = {
    filename = "__tank-squads__/graphics/command-icons/rally.png",
    width = 128,
    height = 128,
    scale = 0.25,
  },
}

local item = util.table.deepcopy(data.raw["item"]["radar"])
item.name = "tank-squad-rally-flag"
item.icon = entity.icon
item.icon_size = entity.icon_size
item.icons = nil
item.place_result = "tank-squad-rally-flag"
item.order = "z-tank-squad-b"
item.subgroup = "defensive-structure"

data:extend{entity, item}
