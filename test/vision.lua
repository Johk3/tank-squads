return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local weapons = require('scripts.weapons')
  local divisions = require('scripts.divisions')
  local vision = require('scripts.vision')

  -- Records every chart call per force and counts how often each chunk is
  -- charted. clear() forgets the calls recorded so far.
  local function watch(force)
    local calls, charted = {}, {}
    force.chart = function(target_surface, area)
      calls[#calls + 1] = {surface = target_surface, area = area}
      for cx = math.floor(area[1].x / 32), math.floor(area[2].x / 32) do
        for cy = math.floor(area[1].y / 32), math.floor(area[2].y / 32) do
          local key = cx .. ':' .. cy
          charted[key] = (charted[key] or 0) + 1
        end
      end
    end
    local function clear()
      for i = #calls, 1, -1 do calls[i] = nil end
      for key in pairs(charted) do charted[key] = nil end
    end
    return calls, charted, clear
  end

  -- Runs whole seconds of sweep slices and returns the most chart calls any
  -- single slice made.
  local second = 0
  local function sweep(seconds, calls)
    local handler = ctx.handlers().nth_tick
    local busiest = 0
    for _ = 1, seconds or 1 do
      second = second + 1
      for tick = second * 60, second * 60 + 59, handler.period do
        local before = calls and #calls or 0
        game.tick = tick
        handler.handler{tick = tick}
        busiest = math.max(busiest, (calls and #calls or 0) - before)
      end
    end
    return busiest
  end

  local function setup()
    dofile('control.lua')
    second = 0
    return game.players[1].force
  end

  local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
  end

  local function assert_area(charted, cx, cy)
    local r = vision.RADIUS
    for x = cx - r, cx + r do
      for y = cy - r, cy + r do
        local n = charted[x .. ':' .. y]
        assert(n == 1, 'chunk ' .. x .. ':' .. y .. ' charted ' .. tostring(n) .. ' times')
      end
    end
  end

  -- A registered headquarters with its helpers made by a stub surface. The
  -- stub makes no power coupling, so the sweep never wires a grid.
  local function headquarters_at(x, y)
    local surface = game.surfaces[1]
    surface.create_entity = function(args)
      if args.name == 'tank-squad-hq-pole' then return nil end
      local e = soldier(nil, nil, args.position.x, args.position.y)
      e.name = args.name
      e.destroy = function() e.valid = false end
      e.get_inventory = function() return nil end
      return e
    end
    local hq = soldier(nil, nil, x, y)
    hq.name = 'tank-squad-headquarters'
    require('scripts.headquarters').register(hq)
    return hq
  end

  test('vision: a headquarters charts the chunks around it like a soldier', function()
    local force = setup()
    local _, charted, clear = watch(force)
    sweep(1)
    local hq = headquarters_at(16, 16)
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert_area(charted, 0, 0)
    local side = 2 * vision.RADIUS + 1
    assert(count(charted) == side * side, 'charted ' .. count(charted) .. ' chunks')
    require('scripts.headquarters').unregister(hq.unit_number)
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert(count(charted) == 0, 'a removed headquarters kept charting')
  end)

  test('vision: switching vision off and on keeps charting around a headquarters', function()
    local force = setup()
    local _, charted, clear = watch(force)
    headquarters_at(16, 16)
    sweep(1)
    settings.global[require('scripts.config').VISION] = {value = false}
    sweep(1)
    settings.global[require('scripts.config').VISION] = {value = true}
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert_area(charted, 0, 0)
  end)

  test('vision: every soldier charts the chunks around it once per second', function()
    local force = setup()
    local calls, charted, clear = watch(force)
    weapons.register(soldier(nil, nil, 16, 16))
    weapons.register(soldier(nil, nil, 1000, -1000))
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert_area(charted, 0, 0)
    assert_area(charted, 31, -32)
    local side = 2 * vision.RADIUS + 1
    assert(count(charted) == 2 * side * side, 'charted ' .. count(charted) .. ' chunks')
  end)

  test('vision: a crowd shares one chart call per chunk column', function()
    local force = setup()
    local calls, charted, clear = watch(force)
    -- 200 soldiers packed in one chunk column, three chunks tall.
    for i = 0, 199 do weapons.register(soldier(nil, nil, 5 + (i % 20), 1 + math.floor(i / 20) * 9)) end
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert(#calls == 2 * vision.RADIUS + 1, #calls .. ' chart calls for one column of soldiers')
    for key, n in pairs(charted) do assert(n == 1, key .. ' charted ' .. n .. ' times') end
  end)

  test('vision: each soldier is read once per read cycle, spread over the slices', function()
    local force = setup()
    local calls, _, clear = watch(force)
    sweep(1) -- vision state exists, so registration reads each soldier once
    local cycle = divisions.PHASES * vision.READ_SECONDS
    local reads = {}
    -- One soldier every five chunks: their areas form one unbroken strip.
    for i = 0, cycle - 1 do
      local e = soldier(nil, nil, i * 32 * 5 + 16, 16)
      weapons.register(e)
      reads[#reads + 1] = ctx.count_reads(e, 'position')
    end
    local handler = ctx.handlers().nth_tick
    local busiest_reads = 0
    for _ = 1, vision.READ_SECONDS do
      second = second + 1
      for tick = second * 60, second * 60 + 59, handler.period do
        local before = 0
        for _, r in ipairs(reads) do before = before + r.n end
        game.tick = tick
        handler.handler{tick = tick}
        local after = 0
        for _, r in ipairs(reads) do after = after + r.n end
        busiest_reads = math.max(busiest_reads, after - before)
      end
    end
    for _, r in ipairs(reads) do assert(r.n == 1, 'soldier position read ' .. r.n .. ' times in one cycle') end
    assert(busiest_reads <= 1, 'one slice read ' .. busiest_reads .. ' positions')
    clear()
    local busiest = sweep(1, calls)
    local columns = cycle * 5
    assert(#calls == columns, #calls .. ' chart calls for ' .. columns .. ' columns')
    assert(busiest <= columns / divisions.PHASES, 'one slice made ' .. busiest .. ' chart calls')
  end)

  test('vision: a moving soldier moves its charted area', function()
    local force = setup()
    local _, charted, clear = watch(force)
    local a = soldier(nil, nil, 16, 16)
    weapons.register(a)
    sweep(vision.READ_SECONDS)
    a.position = {x = 16 + 32 * 20, y = 16}
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert_area(charted, 20, 0)
    assert(charted['0:0'] == nil, 'old area still charted')
    local side = 2 * vision.RADIUS + 1
    assert(count(charted) == side * side, 'charted ' .. count(charted) .. ' chunks')
  end)

  test('vision: soldiers chart for their own force only', function()
    local force = setup()
    local other = {index = 2}
    game.forces[2] = other
    local mine = watch(force)
    local theirs = watch(other)
    weapons.register(soldier(other, nil, 16, 16))
    sweep(vision.READ_SECONDS + 1)
    assert(#mine == 0, 'soldier charted for a foreign force')
    assert(#theirs > 0, 'soldier did not chart for its own force')
  end)

  test('vision: dead soldiers stop charting and leave no counts behind', function()
    local force = setup()
    local calls, _, clear = watch(force)
    local a, b = soldier(nil, nil, 16, 16), soldier(nil, nil, 1000, 16)
    weapons.register(a)
    weapons.register(b)
    sweep(vision.READ_SECONDS)
    a.valid = false
    weapons.unregister(b.unit_number)
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert(#calls == 0, 'dead soldiers kept charting')
    local state = storage.vision
    for s, slice in pairs(state.slices) do assert(not next(slice), 'slice ' .. s .. ' kept a dead soldier') end
    assert(not next(state.occupied), 'occupied chunks leaked')
    for p, bucket in pairs(state.coverage) do assert(not next(bucket), 'coverage of slice ' .. p .. ' leaked') end
  end)

  test('vision: a soldier deployed later is charted in the next second', function()
    local force = setup()
    local _, charted = watch(force)
    sweep(1)
    weapons.register(soldier(nil, nil, 16, 16))
    sweep(1)
    assert_area(charted, 0, 0)
  end)

  test('vision: saves from before vision track every registered soldier', function()
    local force = setup()
    local calls, _, clear = watch(force)
    weapons.register(soldier(nil, nil, 16, 16))
    storage.vision = nil
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert(#calls == 2 * vision.RADIUS + 1, 'soldier registered before vision was not tracked')
  end)

  test('vision: the map setting switches charting off and back on', function()
    local force = setup()
    local calls, charted, clear = watch(force)
    weapons.register(soldier(nil, nil, 16, 16))
    settings.global['tank-squads-soldier-vision'] = {value = false}
    sweep(vision.READ_SECONDS + 1)
    assert(#calls == 0, 'charted while switched off')
    assert(storage.vision == nil, 'kept vision state while switched off')
    settings.global['tank-squads-soldier-vision'] = {value = true}
    sweep(vision.READ_SECONDS)
    clear()
    sweep(1)
    assert_area(charted, 0, 0)
  end)
end
