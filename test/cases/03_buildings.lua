for _, n in pairs({"tank-squad-barracks", "tank-squad-rally-flag"}) do
  if not prototypes.entity[n] then error("missing entity " .. n) end
  if not prototypes.item[n] then error("missing item " .. n) end
  if not prototypes.recipe[n] then error("missing recipe " .. n) end
end
local tech = prototypes.technology["tank-squad-unlock"]
if not tech then error("missing technology tank-squad-unlock") end
local unlocks = 0
for _, eff in pairs(tech.effects) do
  if eff.type == "unlock-recipe" then unlocks = unlocks + 1 end
end
if unlocks ~= 7 then error("technology unlocks " .. unlocks .. " recipes, expected 7 (barracks, rally flag, three carrier tiers and two specialists)") end
local s = game.surfaces[1]
local b = s.create_entity{name = "tank-squad-barracks", position = {10, 10}, force = "player"}
if not b then error("could not place barracks") end
b.set_recipe("tank-squad-train-1")
local recipe = b.get_recipe()
if not recipe or recipe.name ~= "tank-squad-train-1" then error("barracks does not accept a training recipe") end
b.destroy()
local f = s.create_entity{name = "tank-squad-rally-flag", position = {12, 12}, force = "player"}
if not f then error("could not place rally flag") end
f.destroy()
