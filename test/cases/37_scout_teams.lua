local engine_game, engine_rendering = game, rendering
local s = game.surfaces[1]
s.request_to_generate_chunks({1600, -1600}, 4)
s.force_generate_chunk_requests()
local test_index = 999993
local old_divisions, old_index = storage.divisions, storage.unit_divisions
local created = {}
local ok, result = pcall(function()
  game = setmetatable({get_player = function(index)
    if index == test_index then return {index = test_index, force = engine_game.forces.player, surface = s, print = function() end} end
    return engine_game.get_player(index)
  end}, {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, name in ipairs({"draw_circle", "draw_text", "draw_line", "draw_sprite", "draw_animation"}) do
    rendering[name] = function(args) args.players = nil; return engine_rendering[name](args) end
  end
  storage.divisions, storage.unit_divisions = {}, {}
  local kinds = {"tank-squad-soldier-1", "tank-squad-soldier-1", "tank-squad-soldier-1", "tank-squad-soldier-1", "tank-squad-flame", "tank-squad-siege"}
  for i, name in ipairs(kinds) do
    local e = s.create_entity{name = name, position = {1590 + i * 3, -1600}, force = "player"}
    if not e then error("could not create " .. name) end
    created[#created + 1] = e
  end
  remote.call("tank-squads", "division_assign", test_index, 1, {left_top = {x = 1585, y = -1605}, right_bottom = {x = 1615, y = -1595}})
  if remote.call("tank-squads", "division_size", test_index, 1) ~= 6 then error("expected 6 soldiers in the division") end
  if not remote.call("tank-squads", "scout_set", test_index, 1, true) then error("scout mode did not start") end
  remote.call("tank-squads", "scout_tick")
  local state = storage.divisions[test_index].slots[1].scout
  if state.team_count ~= 2 then error("expected 2 teams, got " .. tostring(state.team_count)) end
  local force = engine_game.forces.player
  for id = 1, 2 do
    local team = state.teams[id]
    if not (team and team.hop and team.target) then error("team " .. id .. " did not start a hop") end
    if force.is_chunk_charted(s, team.target) then error("team " .. id .. " targeted a charted chunk") end
    local dx, dy = team.target.x * 32 + 16 - state.origin.x, team.target.y * 32 + 16 - state.origin.y
    local angle = math.atan2(dy, dx) % (2 * math.pi)
    local inside = false
    for _, r in ipairs(team.sectors) do if angle >= r.from and angle < r.to then inside = true end end
    if not inside then error("team " .. id .. " targeted a chunk outside its sector") end
  end
  local function kind(e)
    if e.name == "tank-squad-siege" then return "siege" end
    if e.name == "tank-squad-flame" then return "flame" end
    return "carrier"
  end
  local found = {{}, {}}
  for _, e in ipairs(created) do
    local id = state.team_of[e.unit_number]
    local hop = state.teams[id].hop
    local d = e.commandable.command.destination
    local f = (d.x - hop.point.x) * hop.heading.x + (d.y - hop.point.y) * hop.heading.y
    local list = found[id]
    list[kind(e)] = list[kind(e)] or {}
    table.insert(list[kind(e)], f)
  end
  local one, two = found[1], found[2]
  if not (one.siege and #one.siege == 1 and one.carrier and #one.carrier == 2 and not one.flame) then error("team 1 is not a siege and 2 carriers") end
  if not (two.flame and #two.flame == 1 and two.carrier and #two.carrier == 2 and not two.siege) then error("team 2 is not a flame tank and 2 carriers") end
  for _, f in ipairs(one.carrier) do if f - one.siege[1] < 25 then error("team 1 siege does not trail its carriers") end end
  for _, f in ipairs(two.carrier) do if two.flame[1] <= f then error("team 2 flame tank does not lead its carriers") end end
  remote.call("tank-squads", "scout_set", test_index, 1, false)
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions = old_divisions, old_index
if not ok then error(result) end
return "PASS: a mixed scouting division forms two teams in formation, each in its own sector"
