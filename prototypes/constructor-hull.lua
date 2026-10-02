-- The constructor drives over trees and rocks: its tracks crush them
-- (scripts/engineers/constructor.lua `crush`). It collides only with its
-- own layer, which every other obstacle it met before gets here. Trees and
-- rocks do not get it, and neither do units, which it already passed
-- through. Its pathfinder uses the same mask, so paths lead straight
-- through forests. Runs in data-final-fixes, so the entities and tiles of
-- every mod get the layer.
local collision = require('collision-mask-util')
local defaults = require('collision-mask-defaults')
local copy = require('util').table.deepcopy
local names = require('scripts.names')

local LAYER = 'tank_squads_constructor'

data:extend{{type = 'collision-layer', name = LAYER}}

local function rock(prototype)
  return prototype.type == 'simple-entity' and prototype.count_as_rock_for_filtered_deconstruction
end

local function crushed(prototype)
  return prototype.type == 'tree' or rock(prototype) or prototype.type == 'unit'
end

-- What the constructor collided with before, through the player layer of the
-- default unit mask. Every holder of that layer already collides with every
-- other holder, so the new layer adds no collision. Entities that block units
-- only through is_object (offshore pump, rail support, rail ramp) do not get
-- it: they stand on water, and water has the player layer.
local function blocks(mask)
  return mask.layers.player
end

for type in pairs(defaults) do
  for _, prototype in pairs(data.raw[type] or {}) do
    if not crushed(prototype) then
      local mask = collision.get_mask(prototype)
      if blocks(mask) then
        mask = copy(mask)
        mask.layers[LAYER] = true
        prototype.collision_mask = mask
      end
    end
  end
end

-- Water and the other tiles units cannot cross.
for _, tile in pairs(data.raw.tile) do
  local mask = tile.collision_mask
  if mask and blocks(mask) then
    mask = copy(mask)
    mask.layers[LAYER] = true
    tile.collision_mask = mask
  end
end

-- Rolling stock still stops it, as it stopped every unit.
data.raw.unit[names.constructor].collision_mask = {layers = {[LAYER] = true, train = true}}
