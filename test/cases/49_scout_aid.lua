local engine_game, engine_rendering = game, rendering
local s = game.surfaces[1]
s.request_to_generate_chunks({-1600, 1600}, 4)
s.force_generate_chunk_requests()
local test_index = 999992
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
  for i = 1, 6 do
    local e = s.create_entity{name = "tank-squad-soldier-1", position = {-1610 + i * 3, 1600}, force = "player"}
    if not e then error("could not create soldier " .. i) end
    created[#created + 1] = e
  end
  remote.call("tank-squads", "division_assign", test_index, 1, {left_top = {x = -1615, y = 1595}, right_bottom = {x = -1585, y = 1605}})
  if remote.call("tank-squads", "division_size", test_index, 1) ~= 6 then error("expected 6 soldiers in the division") end
  if not remote.call("tank-squads", "scout_set", test_index, 1, true) then error("scout mode did not start") end
  local state = storage.divisions[test_index].slots[1].scout
  for _ = 1, 5 do
    remote.call("tank-squads", "scout_tick")
    if state.teams and state.teams[1].hop and state.teams[2] and state.teams[2].hop then break end
  end
  if state.team_count ~= 2 then error("expected 2 teams, got " .. tostring(state.team_count)) end
  local caller, helper = state.teams[1], state.teams[2]
  if not (caller.hop and caller.back and helper.hop) then error("the teams did not start hopping") end
  local back = caller.back.point
  for _, unit in ipairs(caller.members) do
    local e = engine_game.get_entity_by_unit_number(unit)
    e.health = e.max_health * 0.7
  end
  remote.call("tank-squads", "scout_tick")
  local call = caller.call
  if not call then error("the hurt team did not call for help") end
  if not (caller.hop and caller.hop.fallback) then error("the hurt team did not fall back") end
  if math.abs(call.point.x - back.x) > 1e-6 or math.abs(call.point.y - back.y) > 1e-6 then
    error("the call is not where the last hop started")
  end
  for _, unit in ipairs(caller.members) do
    local d = engine_game.get_entity_by_unit_number(unit).commandable.command.destination
    if (d.x - back.x) ^ 2 + (d.y - back.y) ^ 2 > 12 ^ 2 then error("a hurt soldier was not sent back") end
  end
  if call.helper ~= 2 or helper.helping ~= 1 then error("the other team did not answer") end
  if not (helper.hop and helper.hop.help) then error("the helper did not set out") end
  for _, unit in ipairs(helper.members) do
    local d = engine_game.get_entity_by_unit_number(unit).commandable.command.destination
    local target = helper.hop.point
    if (d.x - target.x) ^ 2 + (d.y - target.y) ^ 2 > 12 ^ 2 then error("a helper soldier was not sent to the help hop") end
  end
  remote.call("tank-squads", "scout_set", test_index, 1, false)
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions = old_divisions, old_index
if not ok then error(result) end
return "PASS: a hurt scout team falls back and calls, and the other team sets out to help"
