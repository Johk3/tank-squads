local t = storage.defend_test
if not t then
  local s = game.surfaces['continuous-combat-test']
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  local a = s.create_entity{name = 'tank-squad-soldier-1', position = {0, 0}, force = 'player', raise_built = true}
  local base = s.create_entity{name = 'biter-spawner', position = {20, 0}, force = 'enemy'}
  base.active = false
  storage.defend_test = {a = a, base = base, started = game.tick}
  a.commandable.set_command{type = defines.command.attack_area, destination = {20, 0}, radius = 12, distraction = defines.distraction.by_enemy}
  return 'WAIT: engaging spawner'
end
local record = storage.weapons[t.a.unit_number]
if t.resuming then
  local resumed = record.target == t.base
  if not resumed and game.tick - t.resuming < 120 then return 'WAIT: resuming base attack' end
  t.a.destroy{raise_destroy = true}
  if t.base.valid then t.base.destroy() end
  storage.defend_test = nil
  if not resumed then error('carrier did not resume base attack after killing the biter') end
  return 'PASS: carrier defended itself and resumed its base attack'
end
if not t.biter then
  if record.target ~= t.base then
    if game.tick - t.started > 360 then error('carrier never engaged spawner') end
    return 'WAIT: engaging spawner'
  end
  t.biter = t.a.surface.create_entity{name = 'big-biter', position = {t.a.position.x - 4, t.a.position.y}, force = 'enemy'}
  t.biter.commandable.set_command{type = defines.command.attack, target = t.a, distraction = defines.distraction.none}
  t.arrived = game.tick
  return 'WAIT: incoming biter'
end
local defended = record.target == t.biter
if not defended and game.tick - t.arrived < 90 then return 'WAIT: carrier should defend itself' end
if defended then
  t.biter.die()
  t.resuming = game.tick
  return 'WAIT: resuming base attack'
end
t.a.destroy{raise_destroy = true}
if t.biter.valid then t.biter.destroy() end
if t.base.valid then t.base.destroy() end
storage.defend_test = nil
if not defended then error('carrier kept attacking the spawner while a nearby biter attacked it') end
return 'PASS: carrier switched from spawner to attacking biter'
