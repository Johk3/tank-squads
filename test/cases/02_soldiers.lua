local expect = { ["tank-squad-soldier-1"] = 400, ["tank-squad-soldier-2"] = 500, ["tank-squad-soldier-3"] = 600 }
for name, hp in pairs(expect) do
  local p = prototypes.entity[name]
  if not p then error("missing prototype " .. name) end
  if p.type ~= "unit" then error(name .. " is type " .. p.type .. ", expected unit") end
  local actual_hp = p.get_max_health("normal")
  if actual_hp ~= hp then error(name .. " has hp " .. actual_hp .. ", expected " .. hp) end
end
local surface = game.surfaces[1]
local e = surface.create_entity{name = "tank-squad-soldier-1", position = {0, 0}, force = "player"}
if not e then error("could not create soldier on player force") end
if not e.commandable then error("soldier has no commandable") end
e.destroy()
