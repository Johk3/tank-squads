local s = game.surfaces[1]
local b = s.create_entity{name = "tank-squad-barracks", position = {-55, -40}, force = "player", raise_built = true}
local clone = b.clone{position = {-60, -40}, surface = s, force = "player"}
if not clone then error("clone not created") end
local count = 0
for _, value in pairs(storage.barracks) do if value.entity == clone then count = count + 1 end end
if count ~= 1 then error("clone registered " .. count .. " times") end
script.raise_event(defines.events.script_raised_revive, {entity = b})
count = 0
for _, value in pairs(storage.barracks) do if value.entity == b then count = count + 1 end end
if count ~= 1 then error("revive registered existing barracks " .. count .. " times") end
b.destroy()
clone.destroy()
