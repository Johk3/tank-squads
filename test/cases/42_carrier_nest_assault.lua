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
  local carriers = {}
  for i = 1, 4 do carriers[i] = make{name = 'tank-squad-soldier-1', position = {X + i * 3, Y + 10}, force = 'player'} end
  local worm = make{name = 'medium-worm-turret', position = {X + 290, Y}, force = 'enemy'}
  worm.active = false
  local spawner = make{name = 'biter-spawner', position = {X + 300, Y}, force = 'enemy'}
  spawner.active = false
  remote.call('tank-squads', 'division_assign', owner, 4, {left_top = {x = X, y = Y + 5}, right_bottom = {x = X + 20, y = Y + 15}})
  if not remote.call('tank-squads', 'escort_start', owner, 4, ward, 'offensive') then error('offensive escort rejected') end
  for _ = 1, 5 do remote.call('tank-squads', 'escort_tick') end
  local record = storage.divisions[owner].slots[4]
  local a = record.escort.assault
  if not (a and a.phase == 'stage') then error('carrier-only offensive escort did not stage at the nest') end
  if record.escort.leg then error('a plain leg ran beside the assault') end
  for _, e in ipairs(carriers) do
    local slot = a.slots[e.unit_number]
    local dx, dy = slot.x - a.center.x, slot.y - a.center.y
    if math.abs(math.sqrt(dx * dx + dy * dy) - (a.radius + 46)) > 0.01 then error('slot off the staging arc') end
    local c = e.commandable.command
    if c.type ~= defines.command.go_to_location then error('a carrier went for the nest before gathering') end
  end
  remote.call('tank-squads', 'escort_tick')
  if a.phase ~= 'stage' then error('carriers attacked before gathering: ' .. a.phase) end
  for _, e in ipairs(carriers) do
    if not e.teleport(a.slots[e.unit_number]) then error('could not place a carrier on its slot') end
  end
  remote.call('tank-squads', 'escort_tick')
  if a.phase ~= 'follow' then error('gathered carriers did not attack: ' .. a.phase) end
  for _, e in ipairs(carriers) do
    local c = e.commandable.command
    if c.type ~= defines.command.attack then error('a gathered carrier did not attack') end
  end
  worm.destroy()
  spawner.destroy()
  remote.call('tank-squads', 'escort_tick')
  if record.escort.assault then error('assault outlived its nest') end
  remote.call('tank-squads', 'escort_stop', owner, 4)
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions = old_divisions, old_index
if not ok then error(result) end
return 'PASS: a carrier-only offensive escort gathers on the staging arc before it attacks the nest'
