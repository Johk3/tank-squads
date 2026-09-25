local engine_game, engine_rendering = game, rendering
local old_divisions, old_index = storage.divisions, storage.unit_divisions
local s = game.surfaces[1]
local X, Y = 3000, -3000
s.request_to_generate_chunks({X, Y}, 8)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{X - 300, Y - 300}, {X + 300, Y + 300}}, force = 'enemy'}) do e.destroy() end
local created = {}
local ok, result = pcall(function()
  storage.divisions, storage.unit_divisions = {}, {}
  local owner = 999993
  local fake = {[owner] = {index = owner, name = 'patrol-retreat-owner', force = engine_game.forces.player, surface = s,
    connected = true, print = function() end}}
  game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
    {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end
  end
  local depot = s.create_entity{name = 'tank-squad-barracks', position = {X + 40, Y}, force = 'player', raise_built = true}
  created[#created + 1] = depot
  local soldiers = {}
  for i = 1, 11 do
    local e = s.create_entity{name = 'tank-squad-soldier-1', position = {X - 10 + i * 2, Y + 10}, force = 'player'}
    created[#created + 1] = e
    soldiers[i] = e
  end
  remote.call('tank-squads', 'division_assign', owner, 6, {left_top = {x = X - 15, y = Y + 5}, right_bottom = {x = X + 20, y = Y + 15}})
  for _, w in ipairs({{x = X - 60, y = Y - 60}, {x = X + 60, y = Y - 60}, {x = X + 60, y = Y + 60}, {x = X - 60, y = Y + 60}}) do
    remote.call('tank-squads', 'patrol_waypoint', owner, 6, w)
  end
  if not remote.call('tank-squads', 'patrol_start', owner, 6) then error('patrol did not start') end
  local r = storage.divisions[owner].slots[6].patrol
  local hurt = soldiers[1]
  hurt.health = 100
  remote.call('tank-squads', 'patrol_tick')
  local away = r.retreat and r.retreat.away or {}
  if not away[hurt.unit_number] then error('injured patrol soldier did not retreat') end
  local c = hurt.commandable.command
  local dx, dy = c.destination.x - depot.position.x, c.destination.y - depot.position.y
  if not (c.type == defines.command.go_to_location and dx * dx + dy * dy < 1) then error('injured soldier not sent to the barracks') end
  local guards = 0
  for unit in pairs(away) do if unit ~= hurt.unit_number then guards = guards + 1 end end
  if guards ~= 1 then error('expected 1 guard for 11 soldiers, got ' .. guards) end
  remote.call('tank-squads', 'patrol_tick')
  if r.posts[hurt.unit_number] then error('the away soldier kept its post') end
  hurt.teleport({X + 40, Y + 4})
  for _ = 1, 20 do remote.call('tank-squads', 'tick') end
  if hurt.health < 380 then error('barracks did not heal the soldier: ' .. hurt.health) end
  remote.call('tank-squads', 'patrol_tick')
  if next(r.retreat.away) then error('convoy did not rejoin after healing') end
  remote.call('tank-squads', 'patrol_tick')
  local post = r.posts[hurt.unit_number]
  if not post then error('healed soldier got no post') end
  c = hurt.commandable.command
  if not (c and c.type == defines.command.go_to_location) then error('healed soldier not sent to its post') end
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions = old_divisions
storage.unit_divisions = old_index
if not ok then error(result) end
return 'PASS: injured patrol soldier retreated with a guard, healed at a real barracks and took up a post again'
