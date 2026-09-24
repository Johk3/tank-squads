local t = storage.next_wave_test
if not t then
  local s = game.surfaces['continuous-combat-test']
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  local a = s.create_entity{name = 'tank-squad-soldier-1', position = {0, 0}, force = 'player', raise_built = true}
  local enemy = s.create_entity{name = 'small-biter', position = {12, 0}, force = 'enemy'}
  enemy.health = 1
  enemy.active = false
  storage.next_wave_test = {a = a, first = enemy, started = game.tick}
  a.commandable.set_command{type = defines.command.go_to_location, destination = {24, 0}, radius = 1, distraction = defines.distraction.by_enemy}
  return 'WAIT: first wave'
end
if not t.enemy then
  if t.first.valid then return 'WAIT: first wave' end
  if not t.finished then t.finished = game.tick end
  if game.tick - t.finished < 15 then return 'WAIT: next wave approaching' end
  t.enemy = t.a.surface.create_entity{name = 'big-biter', position = {t.a.position.x + 8, 0}, force = 'enemy'}
  t.enemy.active = false
  t.arrived = game.tick
  return 'WAIT: next wave'
end
local record = storage.weapons[t.a.unit_number]
local fired = record.target == t.enemy
if not fired and game.tick - t.arrived < 120 then return 'WAIT: acquiring next wave' end
local delay = fired and record.last_shot - t.arrived or 999
t.a.destroy{raise_destroy = true}
if t.enemy.valid then t.enemy.destroy() end
storage.next_wave_test = nil
if delay > 30 then error('paused ' .. delay .. ' ticks before firing at new enemy in range') end
return 'PASS: next wave engaged within ' .. delay .. ' ticks'
