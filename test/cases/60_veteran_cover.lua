local engine_game, engine_rendering = game, rendering
local old_divisions = storage.divisions
local old_index = storage.unit_divisions
local old_cover = storage.cover
local s = game.surfaces[1]
local X, Y = 3000, -3000
s.request_to_generate_chunks({X, Y}, 6)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{X - 200, Y - 200}, {X + 200, Y + 200}}}) do
  if e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = X - 120, X + 120 do for y = Y - 120, Y + 120 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
local created = {}
local ok, result = pcall(function()
  storage.divisions = {}
  storage.unit_divisions = {}
  storage.cover = nil
  local owner = 999995
  local shown = {}
  local fake = {[owner] = {index = owner, name = 'cover-owner', force = engine_game.forces.player, surface = s,
    connected = true, print = function() end,
    create_local_flying_text = function(args) shown[#shown + 1] = args end}}
  game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
    {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil; args.forces = nil; return engine_rendering[method](args) end
  end
  local function spawn(name, x, y, force)
    local e = s.create_entity{name = name, position = {x, y}, force = force or 'player', raise_built = true}
    created[#created + 1] = e
    return e
  end
  local function command_of(e) return e.commandable.command end

  local vip = spawn('tank-squad-soldier-1', X - 60, Y - 60)
  local others = {}
  for i = 1, 4 do others[i] = spawn('tank-squad-soldier-1', X - 60 + 6 * i, Y - 50) end
  remote.call('tank-squads', 'division_assign', owner, 6, {left_top = {x = X - 70, y = Y - 70}, right_bottom = {x = X - 20, y = Y - 40}})
  if remote.call('tank-squads', 'veteran_add_xp', vip.unit_number, 1000) ~= 3 then error('no Veteran') end
  remote.call('tank-squads', 'cover_tick')
  for i, e in ipairs(others) do
    local c = command_of(e)
    if not (c and c.type == defines.command.go_to_location) then error('soldier ' .. i .. ' is not a cover') end
    local dx, dy = c.destination.x - vip.position.x, c.destination.y - vip.position.y
    if math.abs(math.sqrt(dx * dx + dy * dy) - 6) > 0.01 then error('cover ' .. i .. ' not beside the veteran') end
  end

  local lone = spawn('tank-squad-soldier-1', X + 60, Y + 60)
  local helpers = {}
  for i = 1, 3 do helpers[i] = spawn('tank-squad-soldier-1', X + 60 + 5 * i, Y - 40) end
  remote.call('tank-squads', 'division_assign', owner, 8, {left_top = {x = X + 50, y = Y - 50}, right_bottom = {x = X + 90, y = Y + 70}})
  if remote.call('tank-squads', 'veteran_add_xp', lone.unit_number, 1000) ~= 3 then error('no second Veteran') end
  for i = 1, 12 do
    local biter = spawn('small-biter', X + 50 + 2 * i, Y + 90, 'enemy')
    biter.active = false
  end
  remote.call('tank-squads', 'cover_tick')
  for i, e in ipairs(helpers) do
    local c = command_of(e)
    if not (c and (c.type == defines.command.attack or c.type == defines.command.attack_area)) then
      error('helper ' .. i .. ' did not answer, command ' .. tostring(c and c.type))
    end
  end
  local c = command_of(lone)
  if not (c and c.type == defines.command.go_to_location and c.destination.y < Y - 40) then
    error('the veteran did not fall back behind its helpers')
  end
  if not (shown[1] and shown[1].text[1] == 'tank-squads.cover-call') then error('no call for help shown') end
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions = old_divisions
storage.unit_divisions = old_index
storage.cover = old_cover
if not ok then error(result) end
return 'PASS: a veteran walks between covers, and a lone veteran calls for help and falls back'
