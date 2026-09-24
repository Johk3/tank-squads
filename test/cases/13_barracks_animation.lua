local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-barracks"}}) do e.destroy() end
local b = s.create_entity{name = "tank-squad-barracks", position = {-40, -40}, force = "player", raise_built = true}
local record
for _, value in pairs(storage.barracks) do if value.entity == b then record = value end end
if not record then error("barracks not registered") end
b.set_recipe("tank-squad-train-1")
b.get_output_inventory().insert{name = "tank-squad-recruit-1", count = 1}
remote.call("tank-squads", "tick")
if not (record.animation and record.animation.valid) then error("deployment animation absent") end
if record.animation.time_to_live ~= 60 then error("deployment does not expire after one cycle") end
if b.get_output_inventory().get_item_count("tank-squad-recruit-1") ~= 0 then error("recruit not consumed") end
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1"}}) do e.destroy() end
b.destroy()
