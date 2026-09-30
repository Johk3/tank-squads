local engine_game, engine_rendering = game, rendering
local old_divisions, old_index, old_shredders = storage.divisions, storage.unit_divisions, storage.shredders
local created, drawings = {}, {}
local ok, err = pcall(function()
  storage.divisions, storage.unit_divisions, storage.shredders = {}, nil, nil
  local s = game.surfaces[1]
  s.request_to_generate_chunks({0, 0}, 6)
  s.force_generate_chunk_requests()
  local owner, force = 65000, game.forces.player
  rendering = {}
  for _, method in ipairs({'draw_circle', 'draw_text', 'draw_line', 'draw_sprite', 'draw_animation'}) do
    rendering[method] = function(args)
      args.players = nil
      local object = engine_rendering[method](args)
      drawings[#drawings + 1] = object
      return object
    end
  end
  local player = {index = owner, force = force, surface = s, connected = false}
  game = setmetatable({get_player = function(n)
    if n == owner then return player end
    return engine_game.get_player(n)
  end}, {__index = function(_, key) return engine_game[key] end})
  for n = 1, 9 do
    local x0 = -160 + n * 32
    for i = 1, 20 do
      created[#created + 1] = assert(s.create_entity{name = 'tank-squad-soldier-1',
        position = {x0 + (i % 5) * 3, -40 + math.floor(i / 5) * 3}, force = force})
    end
    assert(remote.call('tank-squads', 'division_assign', owner, n,
      {left_top = {x = x0 - 1, y = -41}, right_bottom = {x = x0 + 14, y = -25}}) == 20)
  end
  for i = 1, 200 do
    local e = assert(s.create_entity{name = 'tank-squad-shredder', position = {-100 + (i % 20) * 4, 40 + math.floor(i / 20) * 4},
      force = force, raise_built = true})
    created[#created + 1] = e
  end
  remote.call('tank-squads', 'shredders_tick')
  for _, record in pairs(storage.shredders.units) do
    record.state = 'parked'
  end
  for run = 1, 3 do
    local p = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'shredders_tick') end
    p.stop(); p.divide(30)
    rcon.print({'', 'Full shredder sweep, 200 parked / 9 divisions, run ', run, ': ', p})
  end
  for run = 1, 3 do
    local p = engine_game.create_profiler()
    for _ = 1, 30 do
      storage.shredders.dirty = true
      remote.call('tank-squads', 'shredders_tick')
    end
    p.stop(); p.divide(30)
    rcon.print({'', 'Full sweep with a split after a change, run ', run, ': ', p})
  end
  -- Patrolling divisions look out for swarms around two soldiers each per
  -- sweep: first with no enemy near, then with 30 loose biters by each.
  for n = 1, 9 do storage.divisions[owner].slots[n].mode = 'patrol' end
  for run = 1, 3 do
    local p = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'shredders_tick') end
    p.stop(); p.divide(30)
    rcon.print({'', 'Full sweep, 9 patrolling divisions, no enemy near, run ', run, ': ', p})
  end
  for n = 1, 9 do
    local x0 = -160 + n * 32
    for i = 1, 30 do
      local biter = s.create_entity{name = 'small-biter', position = {x0 + (i % 6) * 2, -60 - math.floor(i / 6) * 2},
        force = 'enemy'}
      if biter then biter.active = false; created[#created + 1] = biter end
    end
  end
  for run = 1, 3 do
    local p = engine_game.create_profiler()
    for _ = 1, 30 do remote.call('tank-squads', 'shredders_tick') end
    p.stop(); p.divide(30)
    rcon.print({'', 'Full sweep, 9 patrolling divisions, 30 loose biters each, run ', run, ': ', p})
  end
end)
for _, e in ipairs(created) do if e.valid then e.destroy() end end
for _, object in ipairs(drawings) do if object.valid then object.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.unit_divisions, storage.shredders = old_divisions, old_index, old_shredders
if not ok then error(err) end
return 'PASS shredder benchmarks completed'
