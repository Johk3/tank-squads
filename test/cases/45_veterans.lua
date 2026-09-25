local t = storage.veterans_case
if not t then
  local s = game.surfaces['veterans-case'] or game.create_surface('veterans-case', {width = 160, height = 160, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 3)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -40, 70 do for y = -40, 70 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['veterans-case'] or game.create_force('veterans-case')
  for _, category in pairs{'bullet', 'cannon-shell', 'flamethrower'} do f.set_ammo_damage_modifier(category, 0) end
  local function unit(name, x, y) return assert(s.create_entity{name = name, position = {x, y}, force = f, raise_built = true}) end
  local killer = unit('tank-squad-soldier-3', 0, 0)
  local record = assert(storage.veterans[killer.unit_number], 'soldier has no service record')
  assert(record.adjective and record.noun and record.xp == 0 and record.rank == 0 and record.kills == 0, 'new soldier is not a recruit')
  record.xp = 49
  local biter = assert(s.create_entity{name = 'small-biter', position = {8, 0}, force = 'enemy'})
  local plain, veteran = unit('tank-squad-soldier-1', 0, 20), unit('tank-squad-soldier-1', 0, 30)
  local siege_plain, siege_veteran = unit('tank-squad-siege', 0, 45), unit('tank-squad-siege', 0, 60)
  assert(remote.call('tank-squads', 'veteran_add_xp', veteran.unit_number, 1000) == 3)
  assert(remote.call('tank-squads', 'veteran_add_xp', siege_veteran.unit_number, 1000) == 3)
  local function silo(x, y) return assert(s.create_entity{name = 'rocket-silo', position = {x, y}, force = 'enemy'}) end
  local targets = {plain = silo(14, 20), veteran = silo(14, 30), siege_plain = silo(30, 45), siege_veteran = silo(30, 60)}
  for key, shooter in pairs{plain = plain, veteran = veteran, siege_plain = siege_plain, siege_veteran = siege_veteran} do
    shooter.commandable.set_command{type = defines.command.attack, target = targets[key], distraction = defines.distraction.none}
  end
  local hq = unit('tank-squad-headquarters', 40, -30)
  local hq_record = assert(storage.veterans[hq.unit_number], 'headquarters has no service record')
  assert(hq_record.adjective and hq_record.xp == nil, 'headquarters earns XP')
  local health = {}
  for key, target in pairs(targets) do health[key] = target.health end
  storage.veterans_case = {killer = killer, biter = biter, started = game.tick, targets = targets, health = health,
    units = {killer, plain, veteran, siege_plain, siege_veteran, hq}, siege_veteran = siege_veteran}
  return 'WAIT: veterans combat'
end
if game.tick - t.started < 130 then return 'WAIT: veterans combat' end
local ok, result = pcall(function()
  local killer = t.killer
  local record = storage.veterans[killer.unit_number]
  assert(not t.biter.valid, 'carrier did not kill the biter')
  assert(record.kills == 1, 'kill not credited: ' .. record.kills)
  assert(math.abs(record.xp - 50.5) < 0.01, 'kill XP not weighted by max health: ' .. record.xp)
  assert(record.rank == 1, 'no promotion at 50 XP')
  assert(math.abs(killer.speed - killer.prototype.speed * 1.1) < 1e-6, 'promotion did not raise speed')
  local lost = {}
  for key, target in pairs(t.targets) do lost[key] = t.health[key] - target.health end
  assert(lost.plain > 0 and lost.siege_plain > 0, 'plain shooters did not fire: ' .. serpent.line(lost))
  local ratio = lost.veteran / lost.plain
  assert(ratio > 1.5 and ratio < 2.0, 'veteran carrier damage ratio ' .. ratio)
  local extra = lost.siege_veteran - lost.siege_plain
  assert(math.abs(extra - 750) < 1, 'veteran shell bonus ' .. extra .. ' (' .. serpent.line(lost) .. ')')
  killer.health = killer.max_health
  killer.damage(100, 'enemy', 'physical')
  local taken = killer.max_health - killer.health
  assert(math.abs(taken - 80) < 0.01, 'Trained soldier lost ' .. taken)
  local id = killer.unit_number
  killer.health = 10
  killer.damage(100, 'enemy', 'physical')
  assert(not killer.valid, 'lethal hit was reduced')
  assert(storage.veterans[id] == nil, 'dead soldier kept its record')
  return string.format('carrier x%.2f, shell +%d, reduction %.0f', ratio, extra, taken)
end)
for _, e in ipairs(t.units) do if e.valid then e.destroy{raise_destroy = true} end end
for _, e in pairs(t.targets) do if e.valid then e.destroy() end end
storage.veterans_case = nil
if not ok then error(result) end
return 'PASS: kill credit, promotion, speed, damage bonus, shell impact bonus and reduction: ' .. result
