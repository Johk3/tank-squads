if not game.get_player(1) then return "SKIP: requires a connected test player; scouting is covered by test/unit.py" end
local s = game.surfaces[1]
local force = game.get_player(1).force
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1"}}) do e.destroy() end
local a = s.create_entity{name = "tank-squad-soldier-1", position = {1200, 1200}, force = force}
local area = {left_top = {x = 1195, y = 1195}, right_bottom = {x = 1205, y = 1205}}
remote.call("tank-squads", "division_assign", 1, 5, area)
local before = 0
for cx = 30, 45 do for cy = 30, 45 do if force.is_chunk_charted(s, {x = cx, y = cy}) then before = before + 1 end end end
remote.call("tank-squads", "scout_set", 1, 5, true)
remote.call("tank-squads", "scout_tick")
local after = 0
for cx = 30, 45 do for cy = 30, 45 do if force.is_chunk_charted(s, {x = cx, y = cy}) then after = after + 1 end end end
if after <= before then error("scouting charted nothing: " .. before .. " -> " .. after) end
local target = remote.call("tank-squads", "scout_target", 1, 5)
if not target then error("scout picked no target chunk") end
if force.is_chunk_charted(s, target) then error("scout targeted an already charted chunk") end
a.destroy()
