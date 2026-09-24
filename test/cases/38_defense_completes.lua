local t = storage.defense_completes_test
if not t then
  local s = game.surfaces['defense-completes-test'] or game.create_surface('defense-completes-test', {width = 128, height = 64, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 2)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  local tiles = {}
  for x = -16, 56 do for y = -24, 24 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  local a = s.create_entity{name = 'tank-squad-soldier-1', position = {0, 0}, force = 'player', raise_built = true}
  local near = s.create_entity{name = 'biter-spawner', position = {15, -6}, force = 'enemy'}
  local far = s.create_entity{name = 'biter-spawner', position = {40, 6}, force = 'enemy'}
  local first = s.create_entity{name = 'small-biter', position = {-6, 0}, force = 'enemy'}
  local second = s.create_entity{name = 'small-biter', position = {-6, 4}, force = 'enemy'}
  near.active, far.active, first.active, second.active = false, false, false, false
  local combat = package.loaded['__tank-squads__/scripts/combat.lua']
  combat.set_command(a, {type = defines.command.attack_area, destination = {x = 15, y = -6}, radius = 32,
    distraction = defines.distraction.by_enemy})
  if storage.assaults[a.unit_number].target ~= near then error('assault did not start at the near nest') end
  local damaged = script.get_event_handler(defines.events.on_entity_damaged)
  damaged{entity = a, cause = first}
  first.destroy()
  near.destroy()
  damaged{entity = a, cause = second}
  second.destroy()
  storage.defense_completes_test = {a = a, far = far, started = game.tick}
  return 'WAIT: defense finishing'
end
local command = t.a.valid and t.a.commandable.command
local advanced = command and command.type == defines.command.attack and command.target == t.far
if not advanced and game.tick - t.started < 300 then return 'WAIT: assault advancing' end
t.a.destroy{raise_destroy = true}
if t.far.valid then t.far.destroy() end
storage.defense_completes_test = nil
if not advanced then error('a defense whose resumed target died never completed, so the assault stalled') end
return 'PASS: the assault moved on to the next nest after a defense outlived its target'
