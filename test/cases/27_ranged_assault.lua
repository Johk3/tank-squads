local t = storage.ranged_assault_test
if not t then
  local s = game.surfaces[1]
  s.request_to_generate_chunks({300, 300}, 2)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{275, 280}, {340, 320}}}) do e.destroy{raise_destroy = true} end
  local tiles = {}
  for x = 275, 340 do for y = 280, 320 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  local a = s.create_entity{name = 'tank-squad-soldier-1', position = {300, 300}, force = 'player', raise_built = true}
  local base = s.create_entity{name = 'biter-spawner', position = {330, 300}, force = 'enemy'}
  base.active = false
  local second = s.create_entity{name = 'biter-spawner', position = {338, 305}, force = 'enemy'}
  second.active = false
  local engine_game, engine_rendering, old_divisions, old_index = game, rendering, storage.divisions, storage.unit_divisions
  local ok, err = pcall(function()
    storage.divisions, storage.unit_divisions = {}, {}
    game = setmetatable({get_player = function() return {force = a.force, surface = s} end}, {__index = function(_, key) return engine_game[key] end})
    rendering = {draw_circle = function(args) args.players = nil; return engine_rendering.draw_circle(args) end}
    remote.call('tank-squads', 'select', 999997, {left_top = {x = 299, y = 299}, right_bottom = {x = 301, y = 301}})
    remote.call('tank-squads', 'order', 999997, {left_top = {x = 329, y = 299}, right_bottom = {x = 331, y = 301}})
    for _, ring in pairs(storage.divisions[999997].slots[0].render.rings) do ring.destroy() end
  end)
  game, rendering, storage.divisions, storage.unit_divisions = engine_game, engine_rendering, old_divisions, old_index
  if not ok then a.destroy{raise_destroy = true}; base.destroy(); second.destroy(); error(err) end
  storage.ranged_assault_test = {a = a, base = base, second = second, started = game.tick}
  return 'WAIT: ranged assault'
end
local record = storage.weapons[t.a.unit_number]
local target = t.next_target and t.second or t.base
if record.target ~= target and game.tick - t.started < 600 then return 'WAIT: approaching spawner' end
local fired = record.target == target
local dx, dy = t.a.position.x - target.position.x, t.a.position.y - target.position.y
local distance = math.sqrt(dx * dx + dy * dy)
if fired and distance >= 18 and not t.next_target then
  t.base.health = 1
  t.next_target = true
  return 'WAIT: automatically advancing to second spawner'
end
t.a.destroy{raise_destroy = true}
if t.base.valid then t.base.destroy() end
if t.second.valid then t.second.destroy() end
storage.ranged_assault_test = nil
if not fired then error('carrier never fired at spawner') end
if distance < 18 then error('carrier charged to within ' .. distance .. ' tiles before firing its 20-tile gun') end
return 'PASS: both spawners engaged at range; second from ' .. distance .. ' tiles'
