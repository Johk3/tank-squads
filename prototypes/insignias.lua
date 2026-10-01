local insignia = require("scripts.insignia")
local ranks = require("scripts.ranks")

-- Drawn far smaller than 256 px in the world and GUI, so mipmaps keep the
-- shrunken badges from shimmering.
local FLAGS = {"mipmap", "linear-minification", "linear-magnification", "linear-mip-level", "no-crop"}

local function sprite(name, filename)
  return {type = "sprite", name = name, filename = filename, size = 256, scale = 2, flags = FLAGS}
end

local sprites = {}
for n, slot in pairs(insignia.SLOTS) do
  sprites[#sprites + 1] = sprite("tank-squad-insignia-" .. n, "__tank-squads__/graphics/insignias/" .. slot.file .. ".png")
end
for rank = 0, ranks.TOP do
  sprites[#sprites + 1] = sprite(ranks.sprite(rank), "__tank-squads__/graphics/veteran-status/" .. ranks.LIST[rank].file .. ".png")
end
data:extend(sprites)
