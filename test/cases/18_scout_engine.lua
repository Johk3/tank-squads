local engine_game, engine_rendering = game, rendering
local s = game.surfaces[1]
local a = s.create_entity{name = "tank-squad-soldier-1", position = {0, 0}, force = "player"}
if not a then error("could not create scout") end
local test_index = 999999
local old_divisions, old_index = storage.divisions, storage.unit_divisions
local ok, result = pcall(function()
  game = setmetatable({get_player = function(index)
    if index == test_index then return {force = a.force, surface = s, print = function() end} end
    return engine_game.get_player(index)
  end}, {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, name in ipairs({"draw_circle", "draw_text", "draw_line", "draw_sprite", "draw_animation"}) do
    rendering[name] = function(args) args.players = nil; return engine_rendering[name](args) end
  end
  storage.divisions, storage.unit_divisions = {}, {}
  local area = {left_top = {x = -1, y = -1}, right_bottom = {x = 1, y = 1}}
  remote.call("tank-squads", "division_assign", test_index, 1, area)
  if remote.call("tank-squads", "division_size", test_index, 1) < 1 then error("scout not assigned") end
  remote.call("tank-squads", "scout_set", test_index, 1, true)
  remote.call("tank-squads", "scout_tick")
  if not remote.call("tank-squads", "scout_target", test_index, 1) then error("scout failed to issue exploration target") end
  remote.call("tank-squads", "patrol_waypoint", test_index, 1, {x = 10, y = 10})
  remote.call("tank-squads", "patrol_waypoint", test_index, 1, {x = 20, y = 20})
  remote.call("tank-squads", "patrol_start", test_index, 1)
  local map_line = storage.divisions[test_index].slots[1].render.route["map-line1"]
  if not map_line or map_line.render_mode ~= "chart" then error("map patrol missing") end
  remote.call("tank-squads", "order", test_index, {left_top = {x = 10, y = 10}, right_bottom = {x = 12, y = 12}})
  if storage.divisions[test_index].slots[1].mode ~= "idle" then error("manual order kept scouting") end
  if map_line.valid then error("cancelled patrol left map line") end
  for _, ring in pairs(storage.divisions[test_index].slots[1].render.rings) do if ring.valid then ring.destroy() end end
end)
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions = old_divisions, old_index
a.destroy()
if not ok then error(result) end
