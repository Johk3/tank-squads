local t = storage.shredder_defence_case
if not t then
  local s = game.surfaces['shredder-defence'] or game.create_surface('shredder-defence', {width = 128, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 3)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -30, 30 do for y = -30, 30 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['shredder-defence'] or game.create_force('shredder-defence')
  local shredder = assert(s.create_entity{name = 'tank-squad-shredder', position = {0, 0}, force = f, raise_built = true})
  local biter = assert(s.create_entity{name = 'medium-biter', position = {6, 0}, force = 'enemy'})
  biter.commandable.set_command{type = defines.command.attack, target = shredder, distraction = defines.distraction.none}
  storage.shredder_defence_case = {surface = s, biter = biter, started = game.tick}
  return 'WAIT: biter attacking a parked shredder'
end
local ok, result = pcall(function()
  local left = t.surface.count_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}
  if (t.biter.valid or left > 0) and game.tick - t.started < 300 then return 'WAIT: biter attacking a parked shredder' end
  assert(not t.biter.valid, 'the shredder did not ram its attacker')
  assert(left == 0, 'the shredder survived its crash')
  return 'rammed its attacker'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
if t.biter.valid then t.biter.destroy() end
for _, e in pairs(t.surface.find_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}) do e.destroy{raise_destroy = true} end
storage.shredder_defence_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
