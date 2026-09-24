local t = storage.headquarters_move_test
if not t then
  local s = game.surfaces['headquarters-test'] or game.create_surface('headquarters-test', {width=512,height=512,autoplace_controls={}})
  s.request_to_generate_chunks({0,0}, 3)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -40, 60 do for y = -30, 30 do tiles[#tiles+1] = {name='grass-1', position={x,y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy=true} end
  local hq = assert(s.create_entity{name='tank-squad-headquarters', position={0,0}, force='player', raise_built=true})
  for y = -12, 12 do
    if math.abs(y) > 1 then s.create_entity{name='stone-wall', position={20, y}, force='player'} end
  end
  local biter = assert(s.create_entity{name='small-biter', position={-3,0}, force='enemy'})
  biter.active = false
  hq.commandable.set_command{type=defines.command.go_to_location, destination={40,0}, radius=2,
    distraction=defines.distraction.none}
  game.speed = 20
  storage.headquarters_move_test = {hq=hq, biter=biter, started=game.tick}
  return 'WAIT: headquarters driving'
end
local hq = t.hq
assert(hq.valid, 'headquarters died on the way')
if math.abs(hq.position.x - 20) < 2.5 then
  t.gap = math.min(t.gap or 99, math.abs(hq.position.y))
end
if hq.position.x < 36 then
  if game.tick - t.started > 5000 then game.speed = 1; error('headquarters stuck at ' .. serpent.line(hq.position)) end
  return 'WAIT: headquarters driving'
end
if not t.arrived then
  game.speed = 1
  t.arrived = game.tick
  t.elapsed = game.tick - t.started
  assert(t.elapsed > 30 * 60 * 0.8, 'moved faster than 0.02 tiles per tick: ' .. t.elapsed .. ' ticks')
  assert(t.gap and t.gap > 3, 'squeezed through the three-tile gap in the wall: ' .. tostring(t.gap))
  local roboport = storage.headquarters[hq.unit_number].helpers.roboport
  assert(roboport.position.x == 0, 'the roboport followed a moving headquarters')
  return 'WAIT: headquarters parking'
end
local s = hq.surface
local record = storage.headquarters[hq.unit_number]
if hq.commandable.command.type ~= defines.command.stop then
  if game.tick - t.arrived > 1800 then error('headquarters never finished its move') end
  return 'WAIT: headquarters parking'
end
t.stopped = t.stopped or game.tick
if game.tick - t.stopped < 150 then return 'WAIT: headquarters parking' end
local roboport = record.helpers.roboport
local dx, dy = roboport.position.x - hq.position.x, roboport.position.y - hq.position.y
assert(dx * dx + dy * dy < 1, 'the camp did not move to the parked headquarters')
assert(t.biter.valid and t.biter.health == t.biter.max_health, 'the unarmed headquarters attacked a biter')
for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy=true} end
assert(storage.headquarters == nil, 'registry not cleared')
storage.headquarters_move_test = nil
return 'PASS: drove 40 tiles in ' .. t.elapsed .. ' ticks around a wall gap, camp stayed behind while driving and moved on parking, never attacked'
