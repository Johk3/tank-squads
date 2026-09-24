local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-barracks", "tank-squad-rally-flag", "tank-squad-soldier-1", "tank-squad-soldier-2", "tank-squad-soldier-3"}}) do e.destroy() end
local b = s.create_entity{name = "tank-squad-barracks", position = {60, 60}, force = "player", raise_built = true}
local flag = s.create_entity{name = "tank-squad-rally-flag", position = {80, 60}, force = "player", raise_built = true}
b.set_recipe("tank-squad-train-1")
b.get_output_inventory().insert{name = "tank-squad-recruit-1", count = 1}
remote.call("tank-squads", "tick")
local made = s.find_entities_filtered{name = "tank-squad-soldier-1", force = "player"}
if #made < 1 then error("no soldier spawned") end
local entry = nil
for _, rec in pairs(storage.barracks) do if rec.entity.valid and rec.entity.unit_number == b.unit_number then entry = rec end end
if not entry then error("barracks not registered") end
if entry.rally_unit_number ~= flag.unit_number then error("barracks did not bind to the flag") end
if not entry.rally_entity or not entry.rally_entity.valid or entry.rally_entity.unit_number ~= flag.unit_number then error("barracks rally_entity did not cache the flag entity") end
flag.destroy()
b.get_output_inventory().insert{name = "tank-squad-recruit-1", count = 1}
remote.call("tank-squads", "tick")
if entry.rally_unit_number ~= nil then error("stale flag binding survived flag destruction and the next build") end
if entry.rally_entity ~= nil then error("stale rally_entity survived flag destruction and the next build") end
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-barracks", "tank-squad-soldier-1"}}) do e.destroy() end
