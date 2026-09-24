if not script.active_mods["tank-squads"] then error("mod not active") end
if script.active_mods["tank-squads"] ~= "0.14.0" then error("wrong version: " .. tostring(script.active_mods["tank-squads"])) end
