if not game.get_player(1) then return "SKIP: requires a connected test player; patrol logic is covered by test/unit.py" end
local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1"}}) do e.destroy() end
local a = s.create_entity{name = "tank-squad-soldier-1", position = {300, 300}, force = "player"}
local b = s.create_entity{name = "tank-squad-soldier-1", position = {303, 300}, force = "player"}
local pindex = 1
remote.call("tank-squads", "select", pindex, {left_top = {x = 295, y = 295}, right_bottom = {x = 310, y = 310}})
remote.call("tank-squads", "patrol_waypoint", pindex, 0, {x = 320, y = 300})
remote.call("tank-squads", "patrol_waypoint", pindex, 0, {x = 320, y = 320})
remote.call("tank-squads", "patrol_start", pindex, 0)
if remote.call("tank-squads", "patrol_index", pindex, 0) ~= 1 then error("patrol did not start at waypoint 1") end
local leader = remote.call("tank-squads", "patrol_leader", pindex, 0)
local follower = (leader == a.unit_number) and b or a
remote.call("tank-squads", "patrol_advance", follower.unit_number)
if remote.call("tank-squads", "patrol_index", pindex, 0) ~= 1 then error("a non-leader completion advanced the patrol") end
remote.call("tank-squads", "patrol_advance", leader)
if remote.call("tank-squads", "patrol_index", pindex, 0) ~= 2 then error("patrol did not advance to waypoint 2") end
remote.call("tank-squads", "patrol_advance", leader)
if remote.call("tank-squads", "patrol_index", pindex, 0) ~= 1 then error("patrol did not wrap to waypoint 1") end
a.destroy()
b.destroy()
