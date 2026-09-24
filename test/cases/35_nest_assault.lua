local engine_game, engine_rendering = game, rendering
local old_divisions, old_index = storage.divisions, storage.unit_divisions
local s = game.surfaces[1]
local X, Y = 3000, 3000
s.request_to_generate_chunks({X + 150, Y}, 10)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{X - 600, Y - 600}, {X + 600, Y + 600}}, force = 'enemy'}) do e.destroy() end
for _, e in pairs(s.find_entities_filtered{area = {{X - 20, Y - 40}, {X + 330, Y + 40}}}) do
  if e.valid and e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = X - 20, X + 330 do for y = Y - 40, Y + 40 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
local created = {}
local function make(args)
  local e = s.create_entity(args)
  if not e then error('could not create ' .. args.name) end
  created[#created + 1] = e
  return e
end
local ok, result = pcall(function()
  storage.divisions, storage.unit_divisions = {}, {}
  local owner, ward = 999994, 999995
  local character = make{name = 'character', position = {X, Y}, force = 'player'}
  local fake = {}
  fake[owner] = {index = owner, name = 'assault-owner', force = engine_game.forces.player, surface = s, connected = true, print = function() end}
  fake[ward] = {index = ward, name = 'assault-ward', force = engine_game.forces.player, surface = s, connected = true, character = character, print = function() end}
  local clock = {tick = engine_game.tick}
  game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
    {__index = function(_, key) if key == 'tick' then return clock.tick end return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil return engine_rendering[method](args) end
  end
  local siege = make{name = 'tank-squad-siege', position = {X + 3, Y + 10}, force = 'player'}
  local flame = make{name = 'tank-squad-flame', position = {X + 6, Y + 10}, force = 'player'}
  local carriers = {}
  for i = 1, 3 do carriers[i] = make{name = 'tank-squad-soldier-1', position = {X + 6 + i * 3, Y + 10}, force = 'player'} end
  local worm = make{name = 'medium-worm-turret', position = {X + 290, Y}, force = 'enemy'}
  worm.active = false
  local spawner = make{name = 'biter-spawner', position = {X + 300, Y}, force = 'enemy'}
  spawner.active = false
  remote.call('tank-squads', 'division_assign', owner, 4, {left_top = {x = X, y = Y + 5}, right_bottom = {x = X + 20, y = Y + 15}})
  if not remote.call('tank-squads', 'escort_start', owner, 4, ward, 'offensive') then error('offensive escort rejected') end
  for _ = 1, 5 do remote.call('tank-squads', 'escort_tick') end
  local record = storage.divisions[owner].slots[4]
  local a = record.escort.assault
  if not (a and a.phase == 'stage') then error('mixed offensive escort did not stage at the nest') end
  if a.worm_range ~= 30 or a.siege_range ~= 52 then error('ranges from prototypes: ' .. a.worm_range .. ' / ' .. a.siege_range) end
  local screened = 0
  for _, role in pairs(a.roles) do if role == 'screen' then screened = screened + 1 end end
  if screened ~= 1 then error('expected one screen carrier, got ' .. screened) end
  for _, e in ipairs({siege, flame, carriers[1], carriers[2], carriers[3]}) do
    local slot = a.slots[e.unit_number]
    local dx, dy = slot.x - a.center.x, slot.y - a.center.y
    if math.abs(math.sqrt(dx * dx + dy * dy) - (a.radius + 46)) > 0.01 then error('slot off the staging arc') end
    if e.commandable.command.type ~= defines.command.go_to_location then error(e.name .. ' not sent to the arc') end
    if not e.teleport(slot) then error('could not place ' .. e.name .. ' on its slot') end
  end
  remote.call('tank-squads', 'escort_tick')
  if a.phase ~= 'barrage' then error('arrived division did not open the barrage: ' .. a.phase) end
  local c = siege.commandable.command
  if not (c.type == defines.command.attack and c.target == worm) then error('siege tank did not open on the worm') end
  if flame.commandable.command.type ~= defines.command.go_to_location then error('flame tank left the arc during the barrage') end
  worm.destroy()
  remote.call('tank-squads', 'escort_tick')
  if a.phase ~= 'push' then error('dead worm did not start the push: ' .. a.phase) end
  c = flame.commandable.command
  if not (c.type == defines.command.attack and c.target == spawner) then error('flame tank did not push onto the spawner') end
  for _, e in ipairs(carriers) do
    if e.commandable.command.type == defines.command.attack then error('a carrier attacked before the flame tank') end
  end
  clock.tick = clock.tick + 481
  remote.call('tank-squads', 'escort_tick')
  if a.phase ~= 'follow' then error('carriers did not follow: ' .. a.phase) end
  local attacking = 0
  for _, e in ipairs(carriers) do
    c = e.commandable.command
    if c.type == defines.command.attack and c.target == spawner then attacking = attacking + 1 end
  end
  if attacking ~= 2 then error('expected 2 attacking carriers, got ' .. attacking) end
  spawner.destroy()
  remote.call('tank-squads', 'escort_tick')
  if record.escort.assault then error('assault outlived its nest') end
  remote.call('tank-squads', 'escort_tick')
  if not record.escort.leg then error('escort did not return to offensive legs') end
  remote.call('tank-squads', 'escort_stop', owner, 4)
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions = old_divisions, old_index
if not ok then error(result) end
return 'PASS: mixed offensive escort stages, barrages the worm, pushes flame, follows with carriers and resumes legs'
