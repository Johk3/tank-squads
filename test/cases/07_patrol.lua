if not game.get_player(1) then return "SKIP: requires a connected test player; patrol logic is covered by test/unit.py" end
local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1"}}) do e.destroy() end
local a = s.create_entity{name = "tank-squad-soldier-1", position = {300, 300}, force = "player"}
local b = s.create_entity{name = "tank-squad-soldier-1", position = {303, 300}, force = "player"}
local pindex = 1
remote.call("tank-squads", "select", pindex, {left_top = {x = 295, y = 295}, right_bottom = {x = 310, y = 310}})
remote.call("tank-squads", "patrol_waypoint", pindex, 0, {x = 320, y = 300})
remote.call("tank-squads", "patrol_waypoint", pindex, 0, {x = 320, y = 400})
remote.call("tank-squads", "patrol_start", pindex, 0)
for _, e in ipairs({a, b}) do
  if remote.call("tank-squads", "patrol_index", pindex, 0, e.unit_number) ~= 0 then error("a soldier did not take up its post first") end
end
remote.call("tank-squads", "patrol_advance", a.unit_number)
if remote.call("tank-squads", "patrol_index", pindex, 0, a.unit_number) == 0 then error("an arrival did not move the soldier on") end
if remote.call("tank-squads", "patrol_index", pindex, 0, b.unit_number) ~= 0 then error("one soldier arriving moved another") end
local target = remote.call("tank-squads", "patrol_target", pindex, 0, a.unit_number)
local destination = a.commandable.command.destination
if math.abs(destination.x - target.x) > 0.01 or math.abs(destination.y - target.y) > 0.01 then error("the soldier was not sent to its next point") end
a.destroy()
b.destroy()
