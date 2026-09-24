local engine_game, engine_rendering = game, rendering
local old_divisions = storage.divisions
local old_index = storage.unit_divisions
local s = game.surfaces[1]
s.request_to_generate_chunks({2000, 2000}, 18)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{2000 - 600, 2000 - 600}, {2000 + 600, 2000 + 600}}, force = 'enemy'}) do
  e.destroy()
end
local created = {}
local ok, result = pcall(function()
  storage.divisions = {}
  storage.unit_divisions = {}
  local owner, ward = 999996, 999997
  local character = s.create_entity{name = 'character', position = {2000, 2000}, force = 'player'}
  created[#created + 1] = character
  local fake = {}
  fake[owner] = {index = owner, name = 'escort-owner', force = engine_game.forces.player, surface = s, connected = true, print = function() end}
  fake[ward] = {index = ward, name = 'escort-ward', force = engine_game.forces.player, surface = s, connected = true, character = character, print = function() end}
  game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
    {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end
  end
  local soldiers = {}
  for i = 1, 4 do
    local e = s.create_entity{name = 'tank-squad-soldier-1', position = {2000 + i * 3, 2010}, force = 'player'}
    created[#created + 1] = e
    soldiers[i] = e
  end
  remote.call('tank-squads', 'division_assign', owner, 4, {left_top = {x = 1995, y = 2005}, right_bottom = {x = 2020, y = 2015}})
  if not remote.call('tank-squads', 'escort_start', owner, 4, ward, 'defensive') then error('defensive escort rejected') end
  for _ = 1, 5 do remote.call('tank-squads', 'escort_tick') end
  local state = remote.call('tank-squads', 'escort_state', owner, 4)
  if not (state and state.available and state.anchor) then error('escort did not anchor on a settled ward') end
  local biter = s.create_entity{name = 'small-biter', position = {2110, 2000}, force = 'enemy'}
  created[#created + 1] = biter
  remote.call('tank-squads', 'escort_tick')
  local attacking = 0
  for _, e in ipairs(soldiers) do
    local c = e.commandable.command
    if c and c.type == defines.command.attack and c.target == biter then attacking = attacking + 1 end
  end
  if attacking ~= 2 then error('expected 2 responders, got ' .. attacking) end
  local dead = {}
  for _, e in ipairs(soldiers) do
    if e.commandable.command.type == defines.command.attack then
      dead[#dead + 1] = e.unit_number
      e.die('enemy')
    end
  end
  remote.call('tank-squads', 'escort_tick')
  local record = storage.divisions[owner].slots[4]
  for _, id in ipairs(dead) do
    if record.escort.slots[id] ~= nil then error('dead responder retained a formation slot') end
    if storage.unit_divisions[id] ~= nil then error('dead responder retained ownership') end
  end
  local replacement = 0
  for _, e in ipairs(soldiers) do
    if e.valid then
      local indexed = storage.unit_divisions[e.unit_number]
      if not indexed or indexed.player_index ~= owner or indexed.division ~= 4 then error('survivor lost ownership') end
      local c = e.commandable.command
      if c.type == defines.command.attack and c.target == biter then replacement = replacement + 1 end
    end
  end
  if replacement ~= 1 then error('survivors failed to replace fallen responders: ' .. replacement) end
  local nest = s.create_entity{name = 'biter-spawner', position = {2300, 2000}, force = 'enemy'}
  created[#created + 1] = nest
  biter.destroy()
  if not remote.call('tank-squads', 'escort_start', owner, 4, ward, 'offensive') then error('offensive escort rejected') end
  remote.call('tank-squads', 'escort_tick')
  local assault = storage.divisions[owner].slots[4].escort.assault
  local staged = false
  for _, structure in ipairs(assault and assault.structures or {}) do if structure.entity == nest then staged = true end end
  if not (staged and assault.phase == 'stage') then error('offensive escort did not stage against the nest') end
  remote.call('tank-squads', 'escort_stop', owner, 4)
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions = old_divisions
storage.unit_divisions = old_index
if not ok then error(result) end
return 'PASS: real responder deaths, formation repair, indexed ownership and offensive targeting'
