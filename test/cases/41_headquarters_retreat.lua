local engine_game, engine_rendering = game, rendering
local old_divisions, old_index = storage.divisions, storage.unit_divisions
local s = game.surfaces[1]
s.request_to_generate_chunks({3000, 3000}, 8)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered{area = {{2700, 2700}, {3300, 3300}}, force = 'enemy'}) do e.destroy() end
local created = {}
local ok, result = pcall(function()
  storage.divisions, storage.unit_divisions = {}, {}
  local owner, ward = 999994, 999995
  local character = s.create_entity{name = 'character', position = {3000, 3000}, force = 'player'}
  created[#created + 1] = character
  local fake = {}
  fake[owner] = {index = owner, name = 'retreat-owner', force = engine_game.forces.player, surface = s, connected = true, print = function() end}
  fake[ward] = {index = ward, name = 'retreat-ward', force = engine_game.forces.player, surface = s, connected = true, character = character, print = function() end}
  game = setmetatable({get_player = function(n) return fake[n] or engine_game.get_player(n) end},
    {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end
  end
  local depot = s.create_entity{name = 'tank-squad-barracks', position = {3200, 3000}, force = 'player', raise_built = true}
  created[#created + 1] = depot
  local hq = s.create_entity{name = 'tank-squad-headquarters', position = {3030, 3010}, force = 'player', raise_built = true}
  created[#created + 1] = hq
  if not (storage.headquarters and storage.headquarters[hq.unit_number]) then error('headquarters not registered') end
  local soldiers = {}
  for i = 1, 11 do
    local e = s.create_entity{name = 'tank-squad-soldier-1', position = {2990 + i * 2, 3010}, force = 'player'}
    created[#created + 1] = e
    soldiers[i] = e
  end
  remote.call('tank-squads', 'division_assign', owner, 5, {left_top = {x = 2985, y = 3005}, right_bottom = {x = 3035, y = 3015}})
  if remote.call('tank-squads', 'division_size', owner, 5) ~= 12 then error('the headquarters did not join the division') end
  if not remote.call('tank-squads', 'escort_start', owner, 5, ward, 'defensive') then error('defensive escort rejected') end
  for _ = 1, 5 do remote.call('tank-squads', 'escort_tick') end
  local state = storage.divisions[owner].slots[5].escort
  if not state.anchor then error('escort did not anchor on a settled ward') end
  local hurt = soldiers[1]
  hurt.health = 100
  remote.call('tank-squads', 'escort_tick')
  local away = state.retreat and state.retreat.away or {}
  if not away[hurt.unit_number] then error('injured soldier did not retreat') end
  local c = hurt.commandable.command
  local dx, dy = c.destination.x - hq.position.x, c.destination.y - hq.position.y
  if not (c.type == defines.command.go_to_location and dx * dx + dy * dy < 1) then error('injured soldier not sent to the nearer headquarters') end
  hq.teleport({3050, 3010})
  hurt.teleport({2992, 3010})
  remote.call('tank-squads', 'escort_tick')
  c = hurt.commandable.command
  dx, dy = c.destination.x - 3050, c.destination.y - 3010
  if dx * dx + dy * dy > 1 then error('convoy did not follow the moving headquarters') end
  hurt.teleport({3050, 3025})
  for _ = 1, 15 do remote.call('tank-squads', 'headquarters_tick') end
  if hurt.health < 380 then error('headquarters did not heal the soldier: ' .. hurt.health) end
  remote.call('tank-squads', 'escort_tick')
  if next(state.retreat.away) then error('convoy did not rejoin after healing') end
  if not remote.call('tank-squads', 'barracks_configure', owner, depot, 5, 1) then error('barracks link rejected') end
  remote.call('tank-squads', 'tick')
  if not depot.active then error('soldiers the barracks did not train filled its quota') end
  remote.call('tank-squads', 'barracks_configure', owner, depot, nil)
  remote.call('tank-squads', 'escort_stop', owner, 5)
end)
for _, e in ipairs(created) do if e.valid then e.destroy{raise_destroy = true} end end
game, rendering = engine_game, engine_rendering
storage.divisions = old_divisions
storage.unit_divisions = old_index
if not ok then error(result) end
return 'PASS: injured soldier retreated to a nearer, moving headquarters, healed there and returned; a linked barracks counts only its own soldiers'
