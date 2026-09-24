local t = storage.continuous_combat_test
if not t then
  local s = game.surfaces['continuous-combat-test'] or game.create_surface('continuous-combat-test', {width = 64, height = 64, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 2)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
  local tiles = {}
  for x = -24, 24 do for y = -24, 24 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  local a = s.create_entity{name = 'tank-squad-soldier-1', position = {0, 0}, force = 'player', raise_built = true}
  local enemies = {}
  for i = 1, 8 do
    local e = s.create_entity{name = 'small-biter', position = {12, i * 2 - 9}, force = 'enemy'}
    e.active = false
    e.health = 1
    enemies[#enemies + 1] = e
  end
  storage.continuous_combat_test = {a = a, enemies = enemies, started = game.tick, last = nil, max_gap = 0, shots = 0}
  local old = script.get_event_handler(defines.events.on_script_trigger_effect)
  script.on_event(defines.events.on_script_trigger_effect, function(event)
    if old then old(event) end
    local state = storage.continuous_combat_test
    if state and event.source_entity == state.a then
      if state.last then state.max_gap = math.max(state.max_gap, event.tick - state.last) end
      state.last, state.shots = event.tick, state.shots + 1
    end
  end)
  a.commandable.set_command{type = defines.command.go_to_location, destination = {20, 0}, radius = 1, distraction = defines.distraction.by_enemy}
  return 'WAIT: firing at successive targets'
end
if t.shots < 8 and game.tick - t.started < 600 then return 'WAIT: successive targets' end
local shots, gap = t.shots, t.max_gap
t.a.destroy{raise_destroy = true}
for _, e in ipairs(t.enemies) do if e.valid then e.destroy() end end
storage.continuous_combat_test = nil
if shots < 8 then error('only fired at ' .. shots .. '/8 available targets') end
if gap > 30 then error('gun paused ' .. gap .. ' ticks between available targets (maximum 30)') end
return 'PASS: maximum target-switch gap ' .. gap .. ' ticks'
