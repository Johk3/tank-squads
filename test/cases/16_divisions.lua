if not game.get_player(1) then return "SKIP: requires a connected test player; divisions are covered by test/unit.py" end
local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1"}}) do e.destroy() end
local a = s.create_entity{name = "tank-squad-soldier-1", position = {900, 900}, force = "player"}
local b = s.create_entity{name = "tank-squad-soldier-1", position = {905, 900}, force = "player"}
local area = {left_top = {x = 895, y = 895}, right_bottom = {x = 910, y = 910}}
if remote.call("tank-squads", "division_assign", 1, 1, area) ~= 2 then error("division 1 did not take both soldiers") end
if remote.call("tank-squads", "division_selected", 1) ~= 1 then error("assignment did not select division 1") end
if remote.call("tank-squads", "division_assign", 1, 2, {left_top = {x = 903, y = 895}, right_bottom = {x = 910, y = 910}}) ~= 1 then error("division 2 did not take one soldier") end
if remote.call("tank-squads", "division_size", 1, 1) ~= 1 then error("membership is not exclusive") end
remote.call("tank-squads", "patrol_waypoint", 1, 1, {x = 950, y = 900})
remote.call("tank-squads", "patrol_waypoint", 1, 1, {x = 950, y = 950})
if remote.call("tank-squads", "patrol_start", 1, 1) ~= 1 then error("division 1 route did not start") end
if remote.call("tank-squads", "patrol_index", 1, 2) ~= nil then error("division 2 inherited a route") end
local route = storage.divisions[1].slots[1].render.route
local lines = 0
for _ in pairs(route) do lines = lines + 1 end
if lines < 4 then error("expected two lines and two numbers for a two-waypoint loop, got " .. lines) end
a.destroy()
b.destroy()
