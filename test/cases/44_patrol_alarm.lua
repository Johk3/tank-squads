local engine_game, engine_rendering = game, rendering
local old_divisions = storage.divisions
local old_index = storage.unit_divisions
local s = game.surfaces[1]
local X, Y = -3000, 3000
s.request_to_generate_chunks({X, Y}, 6)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{X - 200, Y - 200}, {X + 200, Y + 200}}}) do
  if e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = X - 80, X + 80 do for y = Y - 80, Y + 80 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
local created = {}
local ok, result = pcall(function()
  storage.divisions = {}
  storage.unit_divisions = {}
  local owner = 999996
  local fake = {[owner] = {index = owner, name = 'alarm-owner', force = engine_game.forces.player, surface = s, connected = true, print = function() end}}
  game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
    {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end
  end
  local function spawn(name, x, y, force)
    local e = s.create_entity{name = name, position = {x, y}, force = force or 'player'}
    created[#created + 1] = e
    return e
  end
  local members = {}
  for i = 1, 4 do members[i] = spawn('tank-squad-soldier-1', X - 60 + 10 * i, Y - 60) end
  remote.call('tank-squads', 'division_assign', owner, 7, {left_top = {x = X - 70, y = Y - 70}, right_bottom = {x = X, y = Y - 50}})
  for _, w in ipairs({{x = X - 60, y = Y - 60}, {x = X + 60, y = Y - 60}, {x = X + 60, y = Y + 60}, {x = X - 60, y = Y + 60}}) do
    remote.call('tank-squads', 'patrol_waypoint', owner, 7, w)
  end
  if not remote.call('tank-squads', 'patrol_start', owner, 7) then error('patrol did not start') end
  for i = 1, 4 do
    local c = members[i].commandable.command
    if not (c and c.type == defines.command.go_to_location) then error('soldier ' .. i .. ' has no post') end
  end
  local biter = spawn('small-biter', X - 40, Y - 52, 'enemy')
  biter.active = false
  local victim = members[1]
  victim.damage(5, 'enemy', 'physical', biter, biter)
  for i = 2, 4 do
    local c = members[i].commandable.command
    if not (c and c.type == defines.command.attack and c.target == biter) then
      error('soldier ' .. i .. ' did not come to help, command ' .. tostring(c and c.type))
    end
  end
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions = old_divisions
storage.unit_divisions = old_index
if not ok then error(result) end
return 'PASS: a patrol soldier under attack calls the rest of its division to help'
