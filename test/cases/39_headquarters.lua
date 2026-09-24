local t = storage.headquarters_test
local HELPERS = {'tank-squad-hq-roboport','tank-squad-hq-radar','tank-squad-hq-solar','tank-squad-hq-accumulator','tank-squad-hq-pole'}
local function helpers(s, position, radius)
  return s.find_entities_filtered{name=HELPERS, position=position, radius=radius or 1}
end
if not t then
  local unit = prototypes.entity['tank-squad-headquarters']
  assert(unit.get_max_health('normal') == 400 and math.abs(unit.speed - 0.02) < 1e-6, 'wrong headquarters health or speed')
  local roboport = prototypes.entity['tank-squad-hq-roboport']
  assert(roboport.logistic_radius == 625 and roboport.construction_radius == 1375, 'roboport reach is not 25x')
  local radar = prototypes.entity['tank-squad-hq-radar']
  assert(radar.get_max_distance_of_nearby_sector_revealed() == 8 and radar.get_max_distance_of_sector_revealed() == 32, 'wrong radar range')
  assert(prototypes.recipe['tank-squad-train-headquarters'].category == 'tank-squad-training', 'headquarters is not built at a barracks')
  local s = game.surfaces['headquarters-test'] or game.create_surface('headquarters-test', {width=512,height=512,autoplace_controls={}})
  s.request_to_generate_chunks({0,0}, 6)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -30, 90 do for y = -30, 30 do tiles[#tiles+1] = {name='grass-1', position={x,y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy=true} end
  s.always_day = true
  local force = game.forces.player
  force.technologies['tank-squad-headquarters'].researched = true
  assert(force.recipes['tank-squad-train-headquarters'].enabled, 'research did not unlock the headquarters')
  local b = assert(s.create_entity{name='tank-squad-barracks', position={0,-20}, force='player', raise_built=true})
  b.set_recipe('tank-squad-train-headquarters')
  for _, ingredient in pairs(prototypes.recipe['tank-squad-train-headquarters'].ingredients) do
    assert(b.insert{name=ingredient.name, count=ingredient.amount} == ingredient.amount, 'barracks cannot hold ' .. ingredient.amount .. ' ' .. ingredient.name)
  end
  assert(b.get_output_inventory().insert{name='tank-squad-recruit-headquarters', count=1} == 1)
  remote.call('tank-squads', 'tick')
  local hqs = s.find_entities_filtered{name='tank-squad-headquarters'}
  assert(#hqs == 1, 'barracks did not deploy the headquarters')
  local hq = hqs[1]
  assert(b.get_output_inventory().is_empty(), 'deployed recruit remains in output')
  assert(not storage.weapons or not storage.weapons[hq.unit_number], 'the unarmed headquarters got a gun')
  local record = assert(storage.headquarters and storage.headquarters[hq.unit_number], 'headquarters not registered')
  assert(record.dish and record.dish.valid, 'radar dish not drawn')
  local found = helpers(s, hq.position)
  assert(#found == 5, 'expected five helpers on the headquarters, found ' .. #found)
  for _, e in pairs(found) do assert(not e.destructible and e.unit_number, e.name .. ' can be damaged or has no unit number') end
  hq.commandable.set_command{type=defines.command.stop, distraction=defines.distraction.none}
  hq.teleport({0, 0})
  remote.call('tank-squads', 'headquarters_tick')
  assert(#helpers(s, {0,0}) == 0, 'helpers followed a headquarters that has not parked')
  remote.call('tank-squads', 'headquarters_tick')
  assert(#helpers(s, {0,0}) == 5, 'helpers did not move to the parked headquarters')
  local near = s.create_entity{name='tank-squad-soldier-1', position={10,0}, force='player'}
  local far = s.create_entity{name='tank-squad-soldier-1', position={40,0}, force='player'}
  near.health, far.health = 100, 100
  hq.health = 100
  remote.call('tank-squads', 'headquarters_tick')
  assert(math.abs(near.health - 120) < 0.01, 'soldier within 24 tiles healed to ' .. near.health)
  assert(far.health == 100, 'soldier 40 tiles away healed')
  assert(hq.health == 100, 'the headquarters healed itself')
  near.destroy(); far.destroy()
  local pole = s.create_entity{name='medium-electric-pole', position={8,0}, force='player'}
  local lamp = s.create_entity{name='small-lamp', position={9,1}, force='player'}
  record.grid_retry = nil
  remote.call('tank-squads', 'headquarters_tick')
  local own = helpers(s, {0,0})
  local hq_pole
  for _, e in pairs(own) do if e.name == 'tank-squad-hq-pole' then hq_pole = e end end
  assert(record.grid == pole, 'not wired to the nearby friendly pole')
  assert(hq_pole.electric_network_id == pole.electric_network_id, 'grids not coupled')
  local roboport = record.helpers.roboport
  assert(roboport.insert{name='construction-robot', count=10} == 10)
  local chest = s.create_entity{name='storage-chest', position={0,6}, force='player'}
  chest.insert{name='wooden-chest', count=5}
  local ghost = s.create_entity{name='entity-ghost', inner_name='wooden-chest', position={70,0}, force='player'}
  assert(ghost, 'ghost not placed')
  game.speed = 20
  storage.headquarters_test = {hq=hq, b=b, pole=pole, lamp=lamp, chest=chest, started=game.tick}
  return 'WAIT: headquarters robots building 70 tiles away'
end
local s = game.surfaces['headquarters-test']
if not t.built then
  local chests = s.find_entities_filtered{name='wooden-chest', position={70,0}, radius=1}
  if #chests == 0 then
    if game.tick - t.started > 7200 then game.speed = 1; error('robots did not build a ghost 70 tiles away') end
    return 'WAIT: headquarters robots building 70 tiles away, ' .. (game.tick - t.started) .. ' ticks'
  end
  assert(t.lamp.energy > 0, 'coupled grid receives no power from the solar decks')
  t.built = game.tick
  t.build_ticks = game.tick - t.started
  local record = storage.headquarters[t.hq.unit_number]
  t.hq.teleport({60, 0})
  remote.call('tank-squads', 'headquarters_tick')
  remote.call('tank-squads', 'headquarters_tick')
  assert(#helpers(s, {60,0}) == 5, 'helpers were not re-placed after parking')
  assert(record.grid == nil, 'wire kept to a pole left behind')
  return 'WAIT: robots returning after the move'
end
if game.tick - t.built < 1800 then return 'WAIT: robots returning after the move' end
game.speed = 1
local record = storage.headquarters[t.hq.unit_number]
assert(record.helpers.pole.electric_network_id ~= t.pole.electric_network_id, 'still coupled after leaving')
local roboport = record.helpers.roboport
local robots = roboport.get_inventory(defines.inventory.roboport_robot).get_item_count('construction-robot')
local network = roboport.logistic_network
local total = robots + (network and network.all_construction_robots or 0) - (network and network.available_construction_robots or 0)
assert(total == 10, 'robots lost or duplicated by moving: ' .. total)
local hq = t.hq
hq.teleport({0,0})
remote.call('tank-squads', 'headquarters_tick')
remote.call('tank-squads', 'headquarters_tick')
s.clone_area{source_area={{-8,-8},{8,8}}, destination_area={{-8,-40},{8,-24}}}
local clones = s.find_entities_filtered{name='tank-squad-headquarters', position={0,-32}, radius=2}
assert(#clones == 1, 'clone missing')
assert(#helpers(s, {0,-32}) == 5, 'clone does not have exactly its own five helpers')
assert(storage.headquarters[clones[1].unit_number].helpers.roboport.get_inventory(defines.inventory.roboport_robot).is_empty(), 'robots duplicated by cloning')
clones[1].destroy{raise_destroy=true}
assert(#helpers(s, {0,-32}) == 0, 'script destruction left helpers')
robots = record.helpers.roboport.get_inventory(defines.inventory.roboport_robot).get_item_count('construction-robot')
assert(robots > 0, 'no robots docked to spill')
hq.die()
assert(#helpers(s, {0,0}) == 0, 'dead headquarters left helpers')
local spilled = 0
for _, e in pairs(s.find_entities_filtered{name='item-on-ground', position={0,0}, radius=10}) do
  if e.stack.name == 'construction-robot' then spilled = spilled + e.stack.count end
end
assert(spilled == robots, 'stored robots were not spilled on death: ' .. spilled .. ' of ' .. robots)
for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy=true} end
assert(storage.headquarters == nil, 'registry not cleared')
storage.headquarters_test = nil
return 'PASS: robots built after ' .. t.build_ticks .. ' ticks; built at a barracks, heals, couples one grid, robots build 70 tiles out, moves, clones and dies cleanly'
