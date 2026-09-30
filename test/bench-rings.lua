local engine_game = game
local old = storage.engineers
local s = game.surfaces[1]
local force = game.forces.player
local created = {}
local area = {{-700, -3700}, {700, -2300}}
local ok, err = pcall(function()
  storage.engineers = nil
  s.request_to_generate_chunks({0, -3000}, 16)
  s.force_generate_chunk_requests()
  for run = 1, 3 do
    local p = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'engineers_tick') end
    p.stop(); p.divide(30)
    rcon.print({'', 'Engineers sweep, no rings, run ', run, ': ', p})
  end
  remote.call('tank-squads', 'engineers_ring_centre', 'player', 1, 0, -3000)
  remote.call('tank-squads', 'engineers_ring_set', 'player', 'spacing', 200)
  remote.call('tank-squads', 'engineers_ring_set', 'player', 'count', 2)
  remote.call('tank-squads', 'engineers_ring_plan', 'player', 1, 1, true)
  local first = remote.call('tank-squads', 'engineers_ring_info', 'player', 1).count
  local r = engine_game.create_profiler()
  for i = 2, first do remote.call('tank-squads', 'engineers_ring_plan', 'player', 1, i, true) end
  r.stop(); r.divide(first - 1)
  rcon.print({'', 'Planning tick (scan, layout, first batch), average of segments 2 to ', first, ': ', r})
  for _ = 1, 200 do remote.call('tank-squads', 'engineers_ring_tick') end
  local p = engine_game.create_profiler()
  remote.call('tank-squads', 'engineers_ring_plan', 'player', 2, 1)
  local planned = remote.call('tank-squads', 'engineers_ring_info', 'player', 2).count
  for i = 2, planned do remote.call('tank-squads', 'engineers_ring_plan', 'player', 2, i) end
  p.stop(); p.divide(planned)
  rcon.print({'', 'Planning one segment with all its ghosts, average of ', planned, ': ', p})
  remote.call('tank-squads', 'engineers_min_team', 0)
  for i = 1, 3 do
    local c = s.create_entity{name = 'tank-squad-constructor', position = {-20 + i * 10, -3000}, force = force, raise_built = true}
    created[#created + 1] = c
    remote.call('tank-squads', 'engineers_set_autonomous', c.unit_number, true)
  end
  for run = 1, 3 do
    local q = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'engineers_tick') end
    q.stop(); q.divide(30)
    rcon.print({'', 'Engineers sweep, 3 autonomous constructors, 2 rings placed, run ', run, ': ', q})
  end
  for run = 1, 3 do
    local q = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'engineers_clearing_tick') end
    q.stop(); q.divide(30)
    rcon.print({'', 'Interior read, one sweep slice, run ', run, ': ', q})
  end
  local soldiers = {}
  for i = 1, 50 do
    soldiers[i] = s.create_entity{name = 'tank-squad-soldier-1', position = {i, -3000}, force = force}
    created[#created + 1] = soldiers[i]
  end
  local q = engine_game.create_profiler()
  for _, e in ipairs(soldiers) do remote.call('tank-squads', 'engineers_go', e.unit_number, e.position.x + 10, -3000) end
  q.stop(); q.divide(#soldiers)
  rcon.print({'', 'An order inside two rings (crossing check), each: ', q})
end)
for _, e in ipairs(created) do if e.valid then e.destroy{raise_destroy = true} end end
for _, e in pairs(s.find_entities_filtered{area = area, type = {'wall', 'gate', 'entity-ghost'}}) do e.destroy() end
for _, t in pairs(force.find_chart_tags(s, area)) do t.destroy() end
remote.call('tank-squads', 'engineers_ring_reset', 'player')
storage.engineers = old
if not ok then error(err) end
return 'PASS ring benchmarks completed'
