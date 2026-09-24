--[[ One test case is one RCON call and therefore runs inside a single tick, so
a ten-second craft cannot complete here. This case proves the machine half:
the barracks accepts a training recipe, accepts its ingredients, and starts
crafting. The deployment half -- a finished recruit becoming a soldier -- is
proved by 13_barracks_animation, which seeds the output inventory directly. ]]
local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-barracks", "tank-squad-rally-flag", "tank-squad-soldier-1", "tank-squad-soldier-2", "tank-squad-soldier-3"}}) do e.destroy() end
--[[ The training recipes are enabled = false in the prototype and only unlocked
by tank-squad-unlock; a fresh test map's force has researched nothing, so
research it here to reach the state a real player would be in. ]]
game.forces["player"].technologies["tank-squad-unlock"].researched = true
local b = s.create_entity{name = "tank-squad-barracks", position = {30, 30}, force = "player", raise_built = true}
b.set_recipe("tank-squad-train-3")
local recipe = b.get_recipe()
if not recipe or recipe.name ~= "tank-squad-train-3" then error("barracks refused the tier 3 training recipe") end
local input = b.get_inventory(defines.inventory.assembling_machine_input)
local inserted = input.insert{name = "steel-plate", count = 15}
inserted = inserted + input.insert{name = "iron-gear-wheel", count = 20}
inserted = inserted + input.insert{name = "uranium-rounds-magazine", count = 10}
if inserted ~= 45 then error("barracks accepted only " .. inserted .. " of 45 ingredient items") end
if b.status == defines.entity_status.no_power then error("barracks wants a power network; energy_source should be void") end
--[[ is_crafting() lags a tick behind script-inserted ingredients (it flips on
the entity's next update, not synchronously on insert), and one RCON call is
one tick, so status is the decisive same-tick signal that crafting has
actually begun rather than merely being eligible to. ]]
if b.status ~= defines.entity_status.working then error("barracks did not start crafting with a recipe and full ingredients") end
remote.call("tank-squads", "tick")
if #s.find_entities_filtered{name = "tank-squad-soldier-3", force = "player"} > 0 then error("a soldier appeared before the craft finished") end
b.destroy()
