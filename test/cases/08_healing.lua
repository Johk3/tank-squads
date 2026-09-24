local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-barracks", "tank-squad-soldier-1"}}) do e.destroy() end
local b = s.create_entity{name = "tank-squad-barracks", position = {400, 400}, force = "player", raise_built = true}
local near = s.create_entity{name = "tank-squad-soldier-1", position = {405, 400}, force = "player"}
local far = s.create_entity{name = "tank-squad-soldier-1", position = {460, 400}, force = "player"}
near.health = 100
far.health = 100
remote.call("tank-squads", "tick")
if math.abs(near.health - 120) > 0.01 then error("soldier near barracks healed to " .. near.health .. ", expected 120") end
if far.health ~= 100 then error("soldier far from barracks healed to " .. far.health .. ", expected 100") end
near.destroy()
far.destroy()
b.destroy()
