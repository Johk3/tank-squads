local t = storage.nuke_case
if not t then
  local s = game.surfaces['nuke-case'] or game.create_surface('nuke-case', {width = 192, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -20, 90 do for y = -30, 30 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['nuke-case'] or game.create_force('nuke-case')
  local tank = assert(s.create_entity{name = 'tank-squad-nuclear', position = {0, 0}, force = f, raise_built = true})
  local target = assert(s.create_entity{name = 'medium-worm-turret', position = {40, 0}, force = 'enemy'})
  local friend = assert(s.create_entity{name = 'tank-squad-soldier-1', position = {50, 0}, force = f, raise_built = true})
  friend.active = false
  tank.commandable.set_command{type = defines.command.attack, target = target, distraction = defines.distraction.none}
  storage.nuke_case = {stage = 'blocked', tank = tank, target = target, friend = friend, started = game.tick,
    health = target.health, friend_health = friend.health}
  return 'WAIT: nuke held back near a friend'
end
local ok, result = pcall(function()
  if t.stage == 'blocked' then
    if game.tick - t.started < 150 then return 'WAIT: nuke held back near a friend' end
    assert(t.friend.valid and t.friend.health == t.friend_health, 'fallback rocket hurt the friend')
    assert(#t.tank.surface.find_entities_filtered{name = 'tank-squad-nuke-detonation'} == 0, 'nuke launched next to a friend')
    local record = storage.weapons[t.tank.unit_number]
    assert(record.next_launch, 'nothing was launched')
    t.friend.destroy{raise_destroy = true}
    record.next_launch = game.tick
    t.stage, t.started = 'clear', game.tick
    return 'WAIT: nuke on a clear target'
  end
  if t.stage == 'clear' then
    if storage.weapons[t.tank.unit_number].next_launch <= t.started then
      if game.tick - t.started > 180 then error('no nuke launched on a clear target') end
      return 'WAIT: nuke on a clear target'
    end
    local walker = assert(t.tank.surface.create_entity{name = 'tank-squad-soldier-1', position = {42, 3}, force = t.tank.force, raise_built = true})
    walker.active = false
    t.walker, t.stage, t.started = walker, 'landing', game.tick
    return 'WAIT: nuke landing'
  end
  if game.tick - t.started < 240 then return 'WAIT: nuke landing' end
  assert(not t.target.valid, 'nuke did not destroy the worm')
  assert(t.walker.valid, 'nuke killed a friend who walked in after launch')
  assert(t.tank.valid, 'nuke hurt its own tank')
  return 'blocked near a friend, fired when clear, spared a late friend'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
for _, key in ipairs({'tank', 'target', 'friend', 'walker'}) do local e = t[key]; if e and e.valid then e.destroy{raise_destroy = true} end end
storage.nuke_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
