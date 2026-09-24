local engine_game, engine_rendering = game, rendering
local old_divisions, old_barracks, old_index = storage.divisions, storage.barracks, storage.unit_divisions
local s = game.surfaces['continuous-combat-test']
local b
local ok, result = pcall(function()
  storage.divisions, storage.barracks, storage.unit_divisions = {}, {}, {}
  local index = 999998
  game = setmetatable({get_player = function(n)
    if n == index then return {force = engine_game.forces.player, surface = s} end
    return engine_game.get_player(n)
  end}, {__index = function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args) args.players = nil; return engine_rendering[method](args) end
  end
  b = s.create_entity{name = 'tank-squad-barracks', position = {-10, -10}, force = 'player', raise_built = true}
  b.set_recipe('tank-squad-train-1')
  if not remote.call('tank-squads', 'barracks_configure', index, b, 2, 2) then error('binding rejected') end
  local output = b.get_output_inventory()
  for _ = 1, 2 do
    if output.insert{name = 'tank-squad-recruit-1', count = 1} ~= 1 then error('fixture output too small') end
    remote.call('tank-squads', 'tick')
  end
  output.insert{name = 'tank-squad-recruit-1', count = 1}
  remote.call('tank-squads', 'tick')
  if remote.call('tank-squads', 'division_size', index, 2) ~= 2 then error('wrong division strength') end
  if output.get_item_count('tank-squad-recruit-1') ~= 1 then error('over-deployed recruits') end
  if b.active then error('production did not pause at full strength') end
  local record = storage.divisions[index].slots[2]
  game.get_entity_by_unit_number(record.members[1]).die()
  remote.call('tank-squads', 'tick')
  if remote.call('tank-squads', 'division_size', index, 2) ~= 2 then error('casualty not replaced') end
  if output.get_item_count('tank-squad-recruit-1') ~= 0 then error('replacement did not consume recruit') end
  local ids = {table.unpack(record.members)}
  for _, id in ipairs(ids) do game.get_entity_by_unit_number(id).die() end
  remote.call('tank-squads', 'tick')
  if not b.active then error('empty division did not resume production') end
  if not remote.call('tank-squads', 'barracks_configure', index, b, 2, 1) then error('target change failed') end
  output.insert{name = 'tank-squad-recruit-1', count = 1}
  remote.call('tank-squads', 'tick')
  if remote.call('tank-squads', 'division_size', index, 2) ~= 1 then error('total loss not replenished') end
  if not remote.call('tank-squads', 'barracks_configure', index, b, nil) then error('disable failed') end
  if not b.active then error('disable did not restore ordinary production') end
end)
for _, e in pairs(s.find_entities_filtered{name = {'tank-squad-soldier-1', 'tank-squad-barracks'}}) do e.destroy{raise_destroy = true} end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.barracks, storage.unit_divisions = old_divisions, old_barracks, old_index
if not ok then error(result) end
return 'PASS: cap, casualty replacement, total loss and production pause/resume'
