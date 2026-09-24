local engine_game, engine_rendering = game, rendering
local old_divisions = storage.divisions
local old_index = storage.unit_divisions
local s = game.surfaces[1]
s.request_to_generate_chunks({3000, 3000}, 12)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{3000 - 400, 3000 - 400}, {3000 + 400, 3000 + 400}}, force = 'enemy'}) do
  e.destroy()
end
local created = {}
local ok, result = pcall(function()
  storage.divisions = {}
  storage.unit_divisions = {}
  local owner, ward = 999994, 999995
  local character = s.create_entity{name = 'character', position = {3000, 3000}, force = 'player'}
  created[#created + 1] = character
  local fake = {}
  fake[owner] = {index = owner, name = 'lanes-owner', force = engine_game.forces.player, surface = s, connected = true, print = function() end}
  fake[ward] = {index = ward, name = 'lanes-ward', force = engine_game.forces.player, surface = s, connected = true, character = character, print = function() end}
  game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
    {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end
  end
  local function spawn(name, x, y)
    local e = s.create_entity{name = name, position = {x, y}, force = 'player'}
    created[#created + 1] = e
    return e
  end

  local guards = {spawn('tank-squad-soldier-1', 3003, 3010), spawn('tank-squad-soldier-1', 3006, 3010)}
  remote.call('tank-squads', 'division_assign', owner, 5, {left_top = {x = 2995, y = 3005}, right_bottom = {x = 3010, y = 3015}})
  if not remote.call('tank-squads', 'escort_start', owner, 5, ward, 'defensive') then error('defensive escort rejected') end
  for _ = 1, 5 do remote.call('tank-squads', 'escort_tick') end
  local state = remote.call('tank-squads', 'escort_state', owner, 5)
  if not (state and state.anchor) then error('escort did not anchor on a settled ward') end
  fake[ward].character = nil
  character.destroy()
  local biter = s.create_entity{name = 'small-biter', position = {3120, 3000}, force = 'enemy'}
  created[#created + 1] = biter
  remote.call('tank-squads', 'escort_tick')
  state = remote.call('tank-squads', 'escort_state', owner, 5)
  if state.available then error('a dead ward is still available') end
  local attacking = 0
  for _, e in ipairs(guards) do
    local c = e.commandable.command
    if c and c.type == defines.command.attack and c.target == biter then attacking = attacking + 1 end
  end
  if attacking ~= 1 then error('expected 1 responder inside the ring of a dead ward, got ' .. attacking) end
  remote.call('tank-squads', 'escort_stop', owner, 5)
  biter.destroy()

  local flame_speed = prototypes.entity['tank-squad-flame'].speed
  if not (flame_speed and math.abs(flame_speed - 0.07) < 1e-6) then error('flame tank speed reads ' .. tostring(flame_speed)) end
  local flame = spawn('tank-squad-flame', 3000, 3050)
  local carriers = {}
  for i = 1, 3 do carriers[i] = spawn('tank-squad-soldier-1', 3000 + i * 4, 3050) end
  remote.call('tank-squads', 'division_assign', owner, 6, {left_top = {x = 2990, y = 3040}, right_bottom = {x = 3020, y = 3060}})
  for _, w in ipairs({{x = 2950, y = 2950}, {x = 3050, y = 2950}, {x = 3050, y = 3050}, {x = 2950, y = 3050}}) do
    remote.call('tank-squads', 'patrol_waypoint', owner, 6, w)
  end
  if not remote.call('tank-squads', 'patrol_start', owner, 6) then error('patrol did not start') end
  if remote.call('tank-squads', 'patrol_leader', owner, 6) ~= flame.unit_number then error('the flame tank does not lead') end
  local centre, distances = {x = 3000, y = 3000}, {}
  for _, e in ipairs({flame, carriers[1], carriers[2], carriers[3]}) do
    local c = e.commandable.command
    if not (c and c.type == defines.command.go_to_location) then error('a patrol member has no leg') end
    local dx, dy = c.destination.x - centre.x, c.destination.y - centre.y
    distances[#distances + 1] = math.sqrt(dx * dx + dy * dy)
  end
  local corner = math.sqrt(2) * 50
  if math.abs(distances[1] - corner) > 0.01 then error('the leader is not on the route: ' .. distances[1]) end
  table.sort(distances, function(a, b) return a > b end)
  for k = 1, 4 do
    local expected = corner * math.sqrt((4 - k + 1) / 4)
    if math.abs(distances[k] - expected) > 0.01 then error('lane ' .. k .. ' at ' .. distances[k] .. ', expected ' .. expected) end
  end
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions = old_divisions
storage.unit_divisions = old_index
if not ok then error(result) end
return 'PASS: a dead ward\'s ring is still defended; a mixed patrol spreads over four lanes behind its flame tank'
