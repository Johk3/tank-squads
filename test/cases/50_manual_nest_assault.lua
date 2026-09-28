local engine_game, engine_rendering = game, rendering
local old_divisions, old_index, old_claims = storage.divisions, storage.unit_divisions, storage.order_assaults
local s = game.surfaces[1]
local X, Y = -3000, 3000
s.request_to_generate_chunks({X + 150, Y}, 10)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{X - 600, Y - 600}, {X + 600, Y + 600}}, force = 'enemy'}) do e.destroy() end
for _, e in pairs(s.find_entities_filtered{area = {{X - 20, Y - 90}, {X + 380, Y + 90}}}) do
  if e.valid and e.type ~= 'character' then e.destroy() end
end
local tiles = {}
for x = X - 20, X + 380 do for y = Y - 90, Y + 90 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
s.set_tiles(tiles)
local created = {}
local function make(args)
  local e = s.create_entity(args)
  if not e then error('could not create ' .. args.name) end
  created[#created + 1] = e
  return e
end
local ok, result = pcall(function()
  storage.divisions, storage.unit_divisions, storage.order_assaults = {}, {}, {}
  local owner = 999993
  local fake = {index = owner, name = 'order-owner', force = engine_game.forces.player, surface = s, connected = true, print = function() end}
  local clock = {tick = engine_game.tick}
  game = setmetatable({get_player = function(n) if n == owner then return fake end return engine_game.get_player(n) end},
    {__index = function(_, key) if key == 'tick' then return clock.tick end return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil return engine_rendering[method](args) end
  end
  local siege = make{name = 'tank-squad-siege', position = {X + 3, Y + 10}, force = 'player'}
  local flame = make{name = 'tank-squad-flame', position = {X + 6, Y + 10}, force = 'player'}
  local carriers = {}
  for i = 1, 3 do carriers[i] = make{name = 'tank-squad-soldier-1', position = {X + 6 + i * 3, Y + 10}, force = 'player'} end
  local members = {siege, flame, carriers[1], carriers[2], carriers[3]}
  local worm = make{name = 'medium-worm-turret', position = {X + 290, Y}, force = 'enemy'}
  worm.active = false
  local spawner = make{name = 'biter-spawner', position = {X + 300, Y}, force = 'enemy'}
  spawner.active = false
  remote.call('tank-squads', 'division_assign', owner, 4, {left_top = {x = X, y = Y + 5}, right_bottom = {x = X + 20, y = Y + 15}})
  remote.call('tank-squads', 'division_recall', owner, 4)
  local kind = remote.call('tank-squads', 'order', owner, {left_top = {x = X + 298, y = Y - 2}, right_bottom = {x = X + 302, y = Y + 2}})
  if kind ~= 'assault' then error('order onto a nest gave ' .. tostring(kind)) end
  local order = storage.divisions[owner].slots[4].order
  local a = order.assault
  if not (a and a.surround and a.phase == 'stage') then error('no surrounding assault') end
  local behind, walking_round = 0, 0
  for _, e in ipairs(members) do
    local slot = a.slots[e.unit_number]
    local dx, dy = slot.x - a.center.x, slot.y - a.center.y
    if math.abs(math.sqrt(dx * dx + dy * dy) - a.standoff) > 0.01 then error('slot off the staging circle') end
    if slot.x > a.center.x + 1 then behind = behind + 1 end
    local c = e.commandable.command
    if c.type == defines.command.compound then walking_round = walking_round + 1
    elseif c.type ~= defines.command.go_to_location then error(e.name .. ' not sent to its slot') end
  end
  if behind < 2 then error('nest not surrounded: ' .. behind .. ' slots behind it') end
  if walking_round < 2 then error('far soldiers do not walk round the nest: ' .. walking_round) end
  for _, e in ipairs(members) do
    if not e.teleport(a.slots[e.unit_number]) then error('could not place ' .. e.name .. ' on its slot') end
  end
  remote.call('tank-squads', 'order_tick')
  if a.phase ~= 'barrage' then error('arrived division did not open the barrage: ' .. a.phase) end
  local c = siege.commandable.command
  if not (c.type == defines.command.attack and c.target == worm) then error('siege tank did not open on the worm') end
  worm.destroy()
  remote.call('tank-squads', 'order_tick')
  if a.phase ~= 'push' then error('dead worm did not start the push: ' .. a.phase) end
  c = flame.commandable.command
  if not (c.type == defines.command.attack and c.target == spawner) then error('flame tank did not push onto the spawner') end
  clock.tick = clock.tick + 481
  remote.call('tank-squads', 'order_tick')
  if a.phase ~= 'follow' then error('carriers did not follow: ' .. a.phase) end
  spawner.destroy()
  remote.call('tank-squads', 'order_tick')
  if order.assault then error('assault outlived its nest') end
  if next(storage.order_assaults) then error('soldiers still held after the nest fell') end
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions, storage.order_assaults = old_divisions, old_index, old_claims
if not ok then error(result) end
return 'PASS: manual order onto a nest surrounds it, barrages the worm, pushes flame, follows with carriers and ends'
