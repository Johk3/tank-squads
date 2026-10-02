local LAYER = 'tank_squads_constructor'

local function shares(a, b)
  for layer in pairs(a) do
    if layer ~= LAYER and b[layer] then return true end
  end
  return false
end

local masks, seen = {}, {}
local function collect(group)
  for name, prototype in pairs(group) do
    local layers = prototype.collision_mask and prototype.collision_mask.layers
    if layers and layers[LAYER] and name ~= 'tank-squad-constructor' then
      local keys = {}
      for layer in pairs(layers) do keys[#keys + 1] = layer end
      table.sort(keys)
      local key = table.concat(keys, ',')
      if not seen[key] then
        seen[key] = true
        masks[#masks + 1] = {name = name, layers = layers}
      end
    end
  end
end
collect(prototypes.entity)
collect(prototypes.tile)

for i, a in ipairs(masks) do
  for j = i + 1, #masks do
    local b = masks[j]
    if not shares(a.layers, b.layers) then
      error(a.name .. ' and ' .. b.name .. ' collide only through the constructor layer')
    end
  end
end

local pump = prototypes.entity['offshore-pump'].collision_mask.layers
local water = prototypes.tile['water'].collision_mask.layers
assert(not (pump[LAYER] and water[LAYER]), 'offshore pump collides with water through the constructor layer')
return 'PASS: the constructor layer adds no collision across ' .. #masks .. ' masks'
