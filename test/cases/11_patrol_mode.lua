if not game.get_player(1) then return "SKIP: requires a connected test player; patrol orders are covered by test/unit.py" end
local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1"}}) do e.destroy() end
local a = s.create_entity{name = "tank-squad-soldier-1", position = {500, 500}, force = "player"}
local pindex = 1
remote.call("tank-squads", "select", pindex, {left_top = {x = 495, y = 495}, right_bottom = {x = 510, y = 510}})
remote.call("tank-squads", "patrol_mode_set", pindex, true)
remote.call("tank-squads", "alt_select", pindex, {left_top = {x = 520, y = 500}, right_bottom = {x = 522, y = 502}})
remote.call("tank-squads", "alt_select", pindex, {left_top = {x = 520, y = 520}, right_bottom = {x = 522, y = 522}})
local r = storage.divisions[pindex].slots[0].patrol
if not r then error("no patrol route recorded after two alt-selects in patrol mode") end
if #r.waypoints ~= 2 then error("expected 2 waypoints, got " .. tostring(#r.waypoints)) end
if not r.leader then error("expected a leader after the route started walking") end
remote.call("tank-squads", "patrol_mode_set", pindex, false)
if not storage.divisions[pindex].slots[0].patrol then error("turning patrol mode off should leave the route running until a new order") end
local kind = remote.call("tank-squads", "alt_select", pindex, {left_top = {x = 600, y = 600}, right_bottom = {x = 602, y = 602}})
if kind == "patrol" then error("alt_select still added a waypoint after patrol mode was turned off") end
if kind ~= "move" then error("expected a move order on empty ground with patrol mode off, got " .. tostring(kind)) end
if storage.divisions[pindex].slots[0].patrol then error("explicit move did not replace the old patrol route") end
a.destroy()
