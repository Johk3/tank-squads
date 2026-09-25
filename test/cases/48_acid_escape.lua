local t = storage.acid_escape_test
local function finish(message)
  if t.a.valid then t.a.destroy{raise_destroy = true} end
  for _, e in pairs(t.surface.find_entities_filtered{type = {'fire', 'unit-spawner'}}) do e.destroy() end
  storage.acid_escape_test = nil
  return message
end
if not t then
  local s = game.surfaces['acid-escape-test'] or game.create_surface('acid-escape-test', {width = 96, height = 64, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 2)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  local tiles = {}
  for x = -24, 40 do for y = -24, 24 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  local a = s.create_entity{name = 'tank-squad-soldier-3', position = {0, 0}, force = 'player', raise_built = true}
  local first = s.create_entity{name = 'biter-spawner', position = {18, 0}, force = 'enemy'}
  local second = s.create_entity{name = 'biter-spawner', position = {18, 12}, force = 'enemy'}
  first.active, second.active = false, false
  local combat = package.loaded['__tank-squads__/scripts/combat.lua']
  combat.set_command(a, {type = defines.command.attack_area, destination = {x = 18, y = 0}, radius = 32,
    distraction = defines.distraction.by_enemy})
  storage.acid_escape_test = {a = a, surface = s, first = first, second = second, started = game.tick}
  return 'WAIT: engaging the first nest'
end
local a = t.a
if not a.valid then finish(); error('soldier died') end
local weapon = storage.weapons[a.unit_number]
local firing = weapon and weapon.target and weapon.target.valid and weapon.target.type == 'unit-spawner'
if not t.pool then
  if not firing then
    if game.tick - t.started > 600 then finish(); error('soldier never engaged the nest') end
    return 'WAIT: engaging the first nest'
  end
  t.pool = {x = a.position.x, y = a.position.y}
  t.surface.create_entity{name = 'acid-splash-fire-worm-big', position = t.pool, force = 'enemy'}
  t.placed = game.tick
  return 'WAIT: standing in acid'
end
local dx, dy = a.position.x - t.pool.x, a.position.y - t.pool.y
if not t.left then
  if dx * dx + dy * dy >= 2.5 * 2.5 then t.left = game.tick; return 'WAIT: resuming the assault' end
  if game.tick - t.placed > 360 then finish(); error('soldier stayed in the acid pool') end
  return 'WAIT: standing in acid'
end
local mission = storage.assaults and storage.assaults[a.unit_number]
if firing and mission then
  return finish('PASS: soldier left the acid in ' .. (t.left - t.placed) .. ' ticks and resumed its assault')
end
if game.tick - t.left > 600 then finish(); error('soldier did not resume its assault after leaving the acid') end
return 'WAIT: resuming the assault'
