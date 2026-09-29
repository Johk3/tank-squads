local engine_game = game
local old = storage.engineers
local created = {}
local ok, err = pcall(function()
  storage.engineers = nil
  local s = game.surfaces[1]
  s.request_to_generate_chunks({0, 0}, 8)
  s.force_generate_chunk_requests()
  local force = game.forces.player
  for run = 1, 3 do
    local p = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'engineers_tick') end
    p.stop(); p.divide(30)
    rcon.print({'', 'Engineers sweep, no constructors, run ', run, ': ', p})
  end
  for i = 0, 999 do
    created[#created + 1] = s.create_entity{name = 'entity-ghost', inner_name = 'stone-wall',
      position = {-200 + (i % 100) * 4, 150 + math.floor(i / 100) * 4}, force = force, raise_built = true}
  end
  for i = 1, 3 do
    created[#created + 1] = s.create_entity{name = 'tank-squad-constructor', position = {-220 + i * 4, 120},
      force = force, raise_built = true}
  end
  remote.call('tank-squads', 'engineers_min_team', 0)
  for run = 1, 3 do
    local p = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'engineers_tick') end
    p.stop(); p.divide(30)
    rcon.print({'', 'Engineers sweep, 3 constructors, 1000 ghosts, run ', run, ': ', p})
  end
end)
for _, e in ipairs(created) do
  if e.valid then e.destroy{raise_destroy = true} end
end
storage.engineers = old
if not ok then error(err) end
return 'PASS constructor benchmarks completed'
