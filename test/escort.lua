return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local geometry = require('scripts.escort_geometry')

  local function close(a, b) return math.abs(a - b) < 1e-6 end

  test('escort geometry: settle needs a full window inside the tolerance', function()
    local history = {}
    for i = 1, 4 do geometry.push(history, {x = i, y = 0}, 5) end
    assert(not geometry.settled(history, 5, 16), 'settled before five sweeps')
    geometry.push(history, {x = 5, y = 0}, 5)
    assert(geometry.settled(history, 5, 16), 'small moves did not settle')
    geometry.push(history, {x = 40, y = 0}, 5)
    assert(#history == 5, 'history not trimmed')
    assert(not geometry.settled(history, 5, 16), 'a 35-tile jump counted as settled')
  end)

  test('escort geometry: slots keep angular order and spread evenly', function()
    local anchor = {x = 0, y = 0}
    local e, n, w, s = soldier(nil, nil, 10, 0), soldier(nil, nil, 0, 10), soldier(nil, nil, -10, 0), soldier(nil, nil, 0, -10)
    local slots = geometry.assign_slots({w, e, s, n}, anchor, 96)
    local p = geometry.slot_position(anchor, 96, slots[e.unit_number])
    assert(close(p.x, 96) and close(p.y, 0), 'east soldier did not keep the east slot')
    p = geometry.slot_position(anchor, 96, slots[n.unit_number])
    assert(close(p.x, 0) and close(p.y, 96), 'north soldier moved slot')
    local three = geometry.assign_slots({e, n, w}, anchor, 96)
    local a, b = three[e.unit_number], three[n.unit_number]
    assert(close((b - a) % (2 * math.pi), 2 * math.pi / 3), 'three slots not 120 degrees apart')
  end)

  test('escort geometry: band points stay inside the band', function()
    local values, i = {0, 0, 0.5, 0.999, 0.25, 0.5}, 0
    local function random() i = i + 1; return values[i] end
    for _ = 1, 3 do
      local p = geometry.band_point({x = 100, y = 100}, 192, 384, random)
      local d = geometry.distance(p, {x = 100, y = 100})
      assert(d >= 192 - 1e-6 and d <= 384 + 1e-6, 'band point at ' .. d)
    end
  end)

  test('escort geometry: nearest half picks the closest soldiers', function()
    local near, mid, far, farther = soldier(nil, nil, 1, 0), soldier(nil, nil, 5, 0), soldier(nil, nil, 50, 0), soldier(nil, nil, 90, 0)
    local picked = geometry.nearest_half({far, near, farther, mid}, {x = 0, y = 0})
    assert(#picked == 2 and picked[1] == near and picked[2] == mid, 'wrong responders')
    assert(#geometry.nearest_half({far}, {x = 0, y = 0}) == 1, 'single soldier not picked')
    assert(geometry.nearest_point({far.position, near.position}, {x = 0, y = 0}) == 2)
    local c = geometry.centroid({near, mid})
    assert(close(c.x, 3) and close(c.y, 0))
  end)

  test('escort geometry: nearest half reads each position once', function()
    local soldiers, reads = {}, {}
    for i = 1, 16 do
      soldiers[i] = soldier(nil, nil, (i * 7) % 16, 0)
      reads[i] = ctx.count_reads(soldiers[i], 'position')
    end
    local picked = geometry.nearest_half(soldiers, {x = 0, y = 0})
    assert(#picked == 8 and picked[1].position.x == 0, 'wrong responders')
    for i = 1, 16 do assert(reads[i].n <= 2, 'sort re-read a position ' .. reads[i].n .. ' times') end
  end)

  local divisions = require('scripts.divisions')
  local patrol = require('scripts.patrol')
  local scout = require('scripts.scout')
  local commands = require('scripts.commands')

  local function fake_escort(n)
    local record = divisions.record(1, n)
    record.mode = 'escort'
    record.escort = {ward = 1, formation = 'defensive', surface_index = 1, history = {}}
    local ring = {valid = true}
    ring.destroy = function() ring.valid = false end
    record.render.escort = {ring = ring}
    return record
  end

  test('escort plumbing: manual orders, patrol and scout end an escort', function()
    local a = soldier()
    divisions.assign(1, 2, {a})
    local record = fake_escort(2)
    local ring = record.render.escort.ring
    commands.order(1, {left_top = {x = 30, y = 30}, right_bottom = {x = 32, y = 32}}, a.surface)
    assert(record.escort == nil and record.mode == 'idle', 'move did not end escort')
    assert(not ring.valid, 'escort marker survived')
    fake_escort(2)
    patrol.add_waypoint(1, 2, {x = 10, y = 0}, a.surface)
    patrol.start(1, 2)
    assert(record.escort == nil and record.mode == 'patrol', 'patrol did not end escort')
    fake_escort(2)
    scout.set(1, 2, true)
    assert(record.escort == nil and record.mode == 'scout', 'scout did not end escort')
  end)

  test('escort plumbing: disabling scout mode leaves an unrelated active escort alone', function()
    local a = soldier()
    divisions.assign(1, 2, {a})
    local record = fake_escort(2)
    local ring = record.render.escort.ring
    -- scout.set(false) is also reachable directly via the remote interface
    -- and the scout shortcut; it must not stomp a division it never started
    -- scouting on in the first place.
    scout.set(1, 2, false)
    assert(record.mode == 'escort' and record.escort ~= nil, 'disabling scout cleared an active escort')
    assert(ring.valid, 'escort marker destroyed by disabling scout')
  end)

  test('escort plumbing: membership listeners run in order and patrol still reacts', function()
    local calls = {}
    divisions.listen_members_changed(function(p, n) calls[#calls + 1] = p .. ':' .. n end)
    local a, b = soldier(), soldier()
    divisions.assign(1, 3, {a, b})
    patrol.add_waypoint(1, 3, {x = 10, y = 0}, a.surface)
    patrol.start(1, 3)
    a.command = nil
    divisions.assign(1, 4, {b})
    assert(calls[#calls] == '1:3' or calls[#calls] == '1:4', 'listener not called')
    assert(a.command and a.command.destination.x == 10, 'patrol listener no longer resends')
  end)

  test('escort plumbing: clearing a division ends its escort', function()
    divisions.assign(1, 5, {soldier()})
    local record = fake_escort(5)
    divisions.clear(1, 5)
    assert(record.escort == nil and record.mode == 'idle')
  end)

  local escort

  local function ward_player(index, x, y)
    local p = game.players[1]
    local character = soldier(nil, nil, x, y)
    character.name, character.type = 'character', 'character'
    local ward = {index = index, name = 'ward' .. index, force = p.force, surface = p.surface, character = character,
      print = function() end, gui = {left = ctx.gui_element(), screen = ctx.gui_element()},
      set_shortcut_toggled = function() end}
    game.players[index] = ward
    return ward
  end

  local function setup()
    escort = require('scripts.escort')
    defines.command.attack, defines.command.stop = 3, 5
    game.players[1].print = function(msg) game.players[1].last_print = msg end
    game.forces = {player = game.players[1].force, enemy = 'enemy'}
    game.players[1].force.is_enemy = function(other) return other == 'enemy' end
    local surface = game.surfaces[1]
    surface.find_units = function() return {} end
    -- The shared stub ignores `type`, so it would report enemy soldiers as
    -- enemy characters too. Escort tests opt in to targets explicitly.
    surface.find_entities_filtered = function() return {} end
    return surface
  end

  test('escort core: start validates division, formation, ward and members', function()
    setup()
    ward_player(2, 0, 0)
    local a = soldier()
    divisions.assign(1, 0, {a})
    assert(select(2, escort.start(1, 0, 2, 'defensive')) == 'division', 'division 0 accepted')
    assert(select(2, escort.start(1, 3, 2, 'defensive')) == 'empty', 'empty division accepted')
    divisions.assign(1, 3, {a})
    assert(select(2, escort.start(1, 3, 2, 'sideways')) == 'formation')
    game.players[2].force = {}
    assert(select(2, escort.start(1, 3, 2, 'defensive')) == 'ward', 'foreign-force ward accepted')
    game.players[2].force = game.players[1].force
    patrol.add_waypoint(1, 3, {x = 5, y = 5}, a.surface)
    patrol.start(1, 3)
    assert(escort.start(1, 3, 2, 'defensive'))
    local record = divisions.record(1, 3)
    assert(record.mode == 'escort' and record.patrol == nil and record.escort.ward == 2, 'escort did not replace patrol')
    assert(escort.start(1, 3, 1, 'offensive'), 'owner cannot escort self')
  end)

  test('escort core: anchor waits for the ward to settle and moves in 64-tile steps', function()
    setup()
    local ward = ward_player(2, 0, 0)
    local a = soldier(nil, nil, 50, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    local state = divisions.record(1, 3).escort
    for _ = 1, 4 do escort.tick() end
    assert(state.anchor == nil, 'anchored before the ward settled')
    escort.tick()
    assert(state.anchor and state.anchor.x == 0, 'did not anchor on a settled ward')
    ward.character.position = {x = 40, y = 0}
    for _ = 1, 6 do escort.tick() end
    assert(state.anchor.x == 0, 'anchor moved for a 40-tile drift')
    ward.character.position = {x = 100, y = 0}
    escort.tick()
    assert(state.anchor.x == 0, 'anchor chased a moving ward')
    for _ = 1, 5 do escort.tick() end
    assert(state.anchor.x == 100, 'anchor did not follow a settled 100-tile move')
  end)

  test('escort core: ward beyond the leash, dead, or on another surface makes the escort wait', function()
    setup()
    local ward = ward_player(2, 0, 0)
    divisions.assign(1, 3, {soldier(nil, nil, 10, 0)})
    escort.start(1, 3, 2, 'offensive')
    local state = divisions.record(1, 3).escort
    for _ = 1, 5 do escort.tick() end
    assert(state.available and state.anchor.x == 0)
    ward.character.position = {x = 1500, y = 0}
    for _ = 1, 6 do escort.tick() end
    assert(not state.available and state.anchor.x == 0, 'escort followed beyond the leash')
    ward.character.position = {x = 900, y = 0}
    for _ = 1, 5 do escort.tick() end
    assert(state.available and state.anchor.x == 900, 'escort did not re-attach inside the leash')
    ward.character = nil
    escort.tick()
    assert(not state.available and #state.history == 0, 'dead ward still available')
    ward.character = soldier(nil, {index = 7}, 900, 0)
    escort.tick()
    assert(not state.available, 'ward on another surface is available')
  end)

  test('escort core: ward removal, force change, dismiss and stop end the escort', function()
    setup()
    ward_player(2, 0, 0)
    local a = soldier()
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    game.players[2].force = {}
    escort.tick()
    assert(divisions.record(1, 3).mode == 'idle', 'force change kept escort')
    assert(game.players[1].last_print, 'owner not told')
    game.players[2].force = game.players[1].force
    escort.start(1, 3, 2, 'defensive')
    assert(not escort.dismiss(1, 1, 3), 'non-ward dismissed')
    assert(escort.dismiss(2, 1, 3) and divisions.record(1, 3).mode == 'idle')
    assert(a.command.type == defines.command.stop, 'dismissed soldiers kept moving')
    escort.start(1, 3, 2, 'defensive')
    escort.forget_ward(2)
    assert(divisions.record(1, 3).escort == nil, 'removed ward kept escort')
    escort.start(1, 3, 2, 'defensive')
    assert(escort.stop(1, 3) and divisions.record(1, 3).escort == nil)
  end)

  test('escort core: forgetting a member after the same-tick cache is populated drops it from the cache', function()
    setup()
    local a, b = soldier(nil, nil, 5, 0), soldier(nil, nil, 6, 0)
    divisions.assign(1, 3, {a, b})
    divisions.get(1, 3) -- populate this tick's same-tick membership cache with both members
    a.valid = false
    divisions.forget(a.unit_number) -- entity destroyed and forgotten mid-tick, after the cache above
    local cached = divisions.cached(1, 3)
    assert(#cached == 1 and cached[1] == b, 'stale same-tick cache still held a forgotten member')
  end)

  test('escort core: a member forgotten after the cache is populated does not reach a live escort', function()
    setup()
    ward_player(2, 0, 0)
    local a, b = soldier(nil, nil, 96, 0), soldier(nil, nil, -96, 0)
    divisions.assign(1, 3, {a, b})
    escort.start(1, 3, 2, 'defensive')
    for _ = 1, 5 do escort.tick() end -- let the anchor settle, same as settle() below
    divisions.get(1, 3) -- populate this tick's same-tick membership cache with both members
    a.valid = false
    divisions.forget(a.unit_number) -- entity destroyed and forgotten mid-tick, after the cache above
    a.command, b.command = nil, nil
    local biter = soldier('enemy', nil, 110, 20)
    game.surfaces[1].find_units = function() return {biter} end
    escort.tick()
    assert(a.command == nil, 'stale cached invalid entity still received an attack order')
    assert(b.command and b.command.type == defines.command.attack, 'surviving member did not respond to the threat')
  end)

  test('escort core: an emptied but reinforced division still offers its ward a dismiss', function()
    setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 5, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    local record = divisions.record(1, 3)
    -- A reinforced division is kept alive with zero members while barracks
    -- catch up (divisions.members_changed skips M.clear when reinforced).
    record.reinforcement_sources = {[999999] = true}
    a.valid = false
    divisions.get(1, 3) -- control.lua's divisions.refresh() does this every sweep, before escort.tick()
    escort.tick()
    local wards = escort.wards()
    assert(record.mode == 'escort', 'reinforced division cleared despite pending reinforcement')
    assert(wards[2] and #wards[2] == 1, 'ward panel lost its entry for a momentarily emptied escort')
  end)

  local function settle(n)
    for _ = 1, n or 5 do escort.tick() end
  end

  test('escort defensive: soldiers take evenly spaced slots 160 tiles out', function()
    setup()
    ward_player(2, 0, 0)
    local a, b = soldier(nil, nil, 10, 0), soldier(nil, nil, -10, 0)
    divisions.assign(1, 3, {a, b})
    escort.start(1, 3, 2, 'defensive')
    settle()
    assert(a.command and a.command.type == defines.command.go_to_location, 'no slot order')
    local d = geometry.distance(a.command.destination, {x = 0, y = 0})
    assert(math.abs(d - 160) < 1e-6, 'slot not on the 160-tile ring')
    assert(a.command.destination.x > 0 and b.command.destination.x < 0, 'slots crossed over')
    a.command = nil
    escort.tick()
    assert(a.command == nil, 'slot reissued without an anchor move')
  end)

  test('escort defensive: nearest half responds to a threat and returns when clear', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local near1, near2 = soldier(nil, nil, 96, 0), soldier(nil, nil, 0, 96)
    local far1, far2 = soldier(nil, nil, -96, 0), soldier(nil, nil, 0, -96)
    divisions.assign(1, 3, {near1, near2, far1, far2})
    escort.start(1, 3, 2, 'defensive')
    settle()
    local biter = soldier('enemy', nil, 110, 20)
    local enemies = {biter}
    surface.find_units = function(q)
      assert(q.condition == 'enemy')
      return enemies
    end
    escort.tick()
    assert(near1.command.type == defines.command.attack and near1.command.target == biter, 'near soldier did not respond')
    assert(near2.command.type == defines.command.attack, 'second nearest did not respond')
    assert(far1.command.type == defines.command.go_to_location, 'far soldier left its slot')
    local outside = soldier('enemy', nil, 300, 0)
    enemies = {outside}
    escort.tick()
    assert(near1.command.type == defines.command.go_to_location, 'responder did not return when zone cleared')
    assert(divisions.record(1, 3).escort.responders == nil)
  end)

  test('escort defensive: an enemy player character counts as a threat regardless of connected count', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 96, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    settle()
    -- A hostile player's own character, not a scripted NPC: the fixture's
    -- single connected player (test/unit.lua) must not gate this off, since
    -- the number of *connected* players says nothing about whether a hostile
    -- character exists on the map (e.g. one player online, one offline-but-
    -- still-placed, or a server with only the victim connected).
    local raider = soldier('enemy', nil, 110, 20)
    raider.name, raider.type = 'character', 'character'
    game.players[6] = {index = 6, name = 'raider', character = raider, force = 'enemy'}
    escort.tick()
    assert(a.command.type == defines.command.attack and a.command.target == raider,
      'enemy player character not treated as a threat')
  end)

  test('escort defensive: responders retarget when their target dies', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 96, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    settle()
    local first, second = soldier('enemy', nil, 100, 0), soldier('enemy', nil, 110, 0)
    local enemies = {first, second}
    surface.find_units = function() return enemies end
    escort.tick()
    assert(a.command.target == first)
    first.valid = false
    enemies = {second}
    escort.tick()
    assert(a.command.target == second, 'responder did not retarget')
  end)

  -- A find_units stub that honours the query area, counts the queries, and
  -- counts each enemy's position reads.
  local function units_in_areas(surface, enemies)
    local queries, reads, at = {n = 0}, {}, {}
    for i, e in ipairs(enemies) do at[i], reads[i] = e.position, ctx.count_reads(e, 'position') end
    surface.find_units = function(q)
      queries.n = queries.n + 1
      local a, b, out = q.area[1], q.area[2], {}
      for i, e in ipairs(enemies) do
        -- A position the test assigned later is a plain field again.
        local p = rawget(e, 'position') or at[i]
        if e.valid and p.x >= a[1] and p.x <= b[1] and p.y >= a[2] and p.y <= b[2] then out[#out + 1] = e end
      end
      return out
    end
    return queries, reads
  end

  test('escort defensive: a biter inside the ring is fought while the ward walks away', function()
    local surface = setup()
    local ward = ward_player(2, 0, 0)
    local east, west = soldier(nil, nil, 96, 0), soldier(nil, nil, -96, 0)
    divisions.assign(1, 3, {east, west})
    escort.start(1, 3, 2, 'defensive')
    settle()
    -- The ward has not stood still yet, so the ring stays centred on 0,0.
    ward.character.position = {x = 400, y = 0}
    local biter = soldier('enemy', nil, -150, 0)
    local queries, reads = units_in_areas(surface, {biter})
    escort.tick()
    assert(divisions.record(1, 3).escort.anchor.x == 0, 'the ring moved with a walking ward')
    assert(west.command.type == defines.command.attack and west.command.target == biter,
      'a biter inside the ring was ignored')
    assert(east.command.type == defines.command.go_to_location, 'the far soldier left the ring')
    assert(queries.n == 2 and reads[1].n == 1, 'distant zones cost ' .. queries.n .. ' queries')
  end)

  test('escort defensive: the ring is defended while the ward is dead', function()
    local surface = setup()
    local ward = ward_player(2, 0, 0)
    local a = soldier(nil, nil, 96, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    settle()
    ward.character = nil
    local biter = soldier('enemy', nil, 120, 30)
    local queries = units_in_areas(surface, {biter})
    escort.tick()
    assert(not divisions.record(1, 3).escort.available)
    assert(a.command.type == defines.command.attack and a.command.target == biter, 'the ring was left undefended')
    assert(queries.n == 1)
    biter.position = {x = 600, y = 0}
    escort.tick()
    assert(a.command.type == defines.command.go_to_location, 'responder did not return to its slot')
  end)

  test('escort defensive: an escort that never attached does not respond', function()
    local surface = setup()
    local ward = ward_player(2, 0, 0)
    local a = soldier(nil, nil, 96, 0)
    divisions.assign(1, 3, {a})
    ward.character = nil
    escort.start(1, 3, 2, 'defensive')
    local queries = units_in_areas(surface, {soldier('enemy', nil, 100, 0)})
    settle()
    assert(queries.n == 0 and a.command.type == defines.command.stop, 'an unattached escort searched for threats')
  end)

  test('escort defensive: a ward near the ring centre costs one query and each threat once', function()
    local surface = setup()
    local ward = ward_player(2, 0, 0)
    local a, b = soldier(nil, nil, 96, 0), soldier(nil, nil, -96, 0)
    divisions.assign(1, 3, {a, b})
    escort.start(1, 3, 2, 'defensive')
    settle()
    ward.character.position = {x = 40, y = 0}
    -- Inside the ward's circle only, inside the ring's circle only, and outside both.
    local near_ward, near_ring, outside = soldier('enemy', nil, 260, 0), soldier('enemy', nil, -220, 0),
      soldier('enemy', nil, 0, 250)
    local queries, reads = units_in_areas(surface, {near_ward, near_ring, outside})
    escort.tick()
    assert(queries.n == 1, 'close zones cost ' .. queries.n .. ' queries')
    for i = 1, 3 do assert(reads[i].n <= 1, 'threat position read ' .. reads[i].n .. ' times') end
    local state = divisions.record(1, 3).escort
    assert(a.command.target == near_ward, 'the threat nearest the ward was not answered first')
    assert(b.command.type == defines.command.go_to_location, 'more than half responded')
    near_ward.valid = false
    escort.tick()
    assert(a.command.target == near_ring, 'a threat inside the ring but beyond the ward was ignored')
    assert(state.responders[a.unit_number] == near_ring)
  end)

  test('escort defensive: a sweep reads each threat position once', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local members = {}
    for i = 1, 8 do members[i] = soldier(nil, nil, 96 * math.cos(i), 96 * math.sin(i)) end
    divisions.assign(1, 3, members)
    escort.start(1, 3, 2, 'defensive')
    settle()
    local enemies, reads = {}, {}
    for i = 1, 6 do
      enemies[i] = soldier('enemy', nil, 100 + i, 10 * i)
      reads[i] = ctx.count_reads(enemies[i], 'position')
    end
    surface.find_units = function() return enemies end
    escort.tick()
    local responders = 0
    for _, e in ipairs(members) do
      if e.command.type == defines.command.attack then responders = responders + 1 end
    end
    assert(responders == 4, 'nearest half did not respond')
    for i = 1, 6 do assert(reads[i].n == 1, 'threat position read ' .. reads[i].n .. ' times in one sweep') end
  end)

  test('escort defensive: ring re-spaces when a soldier dies', function()
    setup()
    ward_player(2, 0, 0)
    local a, b, c = soldier(nil, nil, 10, 0), soldier(nil, nil, 0, 10), soldier(nil, nil, -10, 0)
    divisions.assign(1, 3, {a, b, c})
    escort.start(1, 3, 2, 'defensive')
    settle()
    local before = divisions.record(1, 3).escort.slots[a.unit_number]
    c.valid = false
    divisions.get(1, 3)
    escort.tick()
    local slots = divisions.record(1, 3).escort.slots
    assert(slots[c.unit_number] == nil, 'dead soldier kept a slot')
    local gap = (slots[b.unit_number] - slots[a.unit_number]) % (2 * math.pi)
    assert(math.abs(gap - math.pi) < 1e-6, 'two survivors not opposite each other')
  end)

  test('escort defensive: real death events batch formation updates until the next sweep', function()
    setup()
    ward_player(2, 0, 0)
    local a, b, c, d = soldier(nil,nil,10,0), soldier(nil,nil,0,10), soldier(nil,nil,-10,0), soldier(nil,nil,0,-10)
    divisions.assign(1, 3, {a,b,c,d})
    escort.start(1, 3, 2, 'defensive')
    settle()
    local calls = 0
    a.commandable.set_command = function(command) calls = calls + 1; a.command = command end
    dofile('control.lua')
    for _, e in ipairs({c,d}) do ctx.handlers().on_entity_died{entity=e}; e.valid=false end
    assert(calls == 0, 'each casualty restarted the formation')
    game.tick = 60
    divisions.refresh()
    escort.tick()
    local slots = divisions.record(1, 3).escort.slots
    assert(slots[c.unit_number] == nil and slots[d.unit_number] == nil, 'dead members retained slots')
    assert(close((slots[b.unit_number] - slots[a.unit_number]) % (2*math.pi), math.pi))
    assert(calls == 1, 'survivor was not repositioned exactly once')
    escort.tick()
    assert(calls == 1, 'formation keeps restarting after casualty handling')
  end)

  test('escort defensive: replace fallen responders without restarting surviving attacks', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local a,b,c,d = soldier(nil,nil,96,0), soldier(nil,nil,90,10), soldier(nil,nil,-96,0), soldier(nil,nil,-90,-10)
    divisions.assign(1,3,{a,b,c,d})
    escort.start(1,3,2,'defensive')
    settle()
    local enemy = soldier('enemy',nil,110,0)
    surface.find_units = function() return {enemy} end
    escort.tick()
    local attacks = 0
    b.commandable.set_command = function(command) attacks=attacks+1; b.command=command end
    dofile('control.lua')
    ctx.handlers().on_entity_died{entity=a}; a.valid=false
    game.tick=60
    divisions.refresh(); escort.tick()
    assert(attacks == 0, 'surviving responder attack restarted')
    assert(c.command.type == defines.command.attack or d.command.type == defines.command.attack, 'no replacement responder')
    for _, e in ipairs({b,c,d}) do
      if e.command.type == defines.command.attack then ctx.handlers().on_entity_died{entity=e}; e.valid=false end
    end
    game.tick=120
    divisions.refresh(); escort.tick()
    for _, e in ipairs({b,c,d}) do
      if e.valid then assert(e.command.type == defines.command.attack, 'response stalled after all responders died') end
    end
  end)

  test('escort offensive: a dead leader cannot leave an already-arrived survivor waiting', function()
    setup()
    ward_player(2,0,0)
    local a,b=soldier(),soldier(nil,nil,10,0)
    divisions.assign(1,3,{a,b})
    escort.start(1,3,2,'offensive')
    settle()
    escort.on_command_completed(b.unit_number,defines.behavior_result.success)
    b.command=nil
    dofile('control.lua')
    ctx.handlers().on_entity_died{entity=a}; a.valid=false
    ctx.handlers().on_ai_command_completed{unit_number=a.unit_number,result=defines.behavior_result.success}
    game.tick=60
    divisions.refresh(); escort.tick()
    assert(b.command, 'survivor waited for an already-consumed completion or leg timeout')
  end)

  test('escort offensive: transferring the leader cannot leave an already-arrived survivor waiting', function()
    setup()
    ward_player(2,0,0)
    local a,b=soldier(),soldier(nil,nil,10,0)
    divisions.assign(1,3,{a,b})
    escort.start(1,3,2,'offensive')
    settle()
    assert(divisions.record(1,3).escort.leg.leader == a.unit_number)
    escort.on_command_completed(b.unit_number,defines.behavior_result.success)
    b.command=nil
    divisions.assign(1,4,{a})
    game.tick=60
    escort.tick()
    assert(b.command, 'survivor waited for the transferred leader or leg timeout')
  end)

  test('escort core: starting an escort cancels the previous order while the ward is unavailable', function()
    setup()
    local ward = ward_player(2,0,0)
    ward.character = nil
    local a = soldier(nil,nil,10,0)
    divisions.assign(1,3,{a})
    a.command = {type = defines.command.go_to_location, destination = {x = 500, y = 0}}
    escort.start(1,3,2,'defensive')
    escort.tick()
    assert(a.command.type == defines.command.stop, 'soldier kept its old destination')
  end)

  test('escort defensive: a recruit burst repositions survivors once', function()
    setup()
    ward_player(2,0,0)
    local a = soldier(nil,nil,96,0)
    divisions.assign(1,3,{a})
    escort.start(1,3,2,'defensive')
    settle()
    local calls = 0
    a.commandable.set_command = function(command) calls = calls + 1; a.command = command end
    local recruits = {}
    for i = 1, 5 do
      local r = soldier(nil,nil,0,i)
      divisions.add_member(1,3,r.unit_number)
      escort.join(divisions.record(1,3), r)
      recruits[i] = r
    end
    assert(calls == 0, 'each recruit restarted the survivors')
    game.tick = 60
    divisions.refresh(); escort.tick()
    assert(calls == 1, 'survivor was not repositioned exactly once')
    for _, r in ipairs(recruits) do
      assert(r.command and r.command.type == defines.command.go_to_location, 'recruit got no slot')
    end
  end)

  local function band_surface(surface, targets)
    surface.find_entities_filtered = function(q)
      local out = {}
      for _, e in ipairs(targets) do
        local dx, dy = e.position.x - q.position.x, e.position.y - q.position.y
        if e.valid and dx * dx + dy * dy <= q.radius * q.radius then out[#out + 1] = e end
      end
      return out
    end
  end

  test('escort offensive: charts every sweep and attacks the nearest enemy in the band', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local a, b = soldier(nil, nil, 5, 0), soldier(nil, nil, 6, 0)
    divisions.assign(1, 3, {a, b})
    local too_close = soldier('enemy', nil, 150, 0)
    local nest = soldier('enemy', nil, 300, 0)
    local far_nest = soldier('enemy', nil, 0, 420)
    band_surface(surface, {too_close, nest, far_nest})
    escort.start(1, 3, 2, 'offensive')
    settle()
    assert(a.command.type == defines.command.attack_area or storage.assaults[a.unit_number], 'no assault leg')
    local leg = divisions.record(1, 3).escort.leg
    assert(leg.destination.x == 300 and leg.destination.y == 0, 'wrong target: ' .. leg.destination.x)
    assert(leg.leader == a.unit_number)
  end)

  test('escort offensive: a leg pick reads each candidate position once and scans forces once', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 5, 0)
    divisions.assign(1, 3, {a})
    local nearest = soldier('enemy', nil, 300, 0)
    local others = {soldier('enemy', nil, 0, 400), soldier('enemy', nil, -350, 0), soldier('enemy', nil, 0, -300)}
    local all = {nearest, others[1], others[2], others[3]}
    surface.find_entities_filtered = function() return all end
    escort.start(1, 3, 2, 'offensive')
    settle()
    local state = divisions.record(1, 3).escort
    -- A failed leg leaves the failure list populated for the next pick.
    escort.on_command_completed(a.unit_number, defines.behavior_result.fail)
    assert(state.leg == nil and next(state.failed), 'test setup: no failed chunk recorded')
    local reads = {}
    for i, e in ipairs(others) do reads[i] = ctx.count_reads(e, 'position') end
    local forces, scans = game.forces, 0
    game.forces = setmetatable({}, {__pairs = function() scans = scans + 1; return next, forces, nil end})
    escort.tick()
    game.forces = forces
    assert(state.leg, 'no next leg')
    -- The blocked nearest nest leaves (0, -300) as the pick; building the
    -- leg reads the winner again, so only the losing candidates are counted.
    assert(state.leg.destination.x == 0 and state.leg.destination.y == -300, 'wrong pick after the failure')
    for i = 1, 2 do assert(reads[i].n == 1, 'candidate ' .. i .. ' position read ' .. reads[i].n .. ' times') end
    assert(scans == 1, 'enemy forces scanned ' .. scans .. ' times for one leg')
  end)

  test('escort offensive: charts on the very first sweep, before the anchor exists', function()
    setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 320, 320)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'offensive')
    local state = divisions.record(1, 3).escort
    escort.tick() -- first sweep: the ward has not settled yet, so state.anchor is still nil
    assert(state.anchor == nil, 'test setup: anchor formed on the first sweep')
    local force = game.players[1].force
    assert(force.is_chunk_charted(game.surfaces[1], {x = 10, y = 10}), 'no charting before the first attach')
  end)

  test('escort offensive: roams to a band point when no enemy is found, next leg on completion', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 5, 0)
    divisions.assign(1, 3, {a})
    band_surface(surface, {})
    escort.start(1, 3, 2, 'offensive')
    settle()
    local state = divisions.record(1, 3).escort
    local d = geometry.distance(state.leg.destination, {x = 0, y = 0})
    assert(d >= 256 and d <= 448, 'roam point outside the band')
    local first = state.leg
    escort.tick()
    assert(state.leg == first, 'leg reissued every sweep')
    assert(escort.on_command_completed(a.unit_number, defines.behavior_result.success))
    assert(state.leg == nil)
    escort.tick()
    assert(state.leg and state.leg ~= first, 'no next leg')
  end)

  test('escort offensive: failed targets are skipped until they expire, stale legs time out', function()
    local surface = setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 5, 0)
    divisions.assign(1, 3, {a})
    local blocked, other = soldier('enemy', nil, 300, 0), soldier('enemy', nil, 0, 400)
    band_surface(surface, {blocked, other})
    escort.start(1, 3, 2, 'offensive')
    settle()
    local state = divisions.record(1, 3).escort
    assert(state.leg.destination.x == 300)
    escort.on_command_completed(a.unit_number, defines.behavior_result.fail)
    escort.tick()
    assert(state.leg.destination.y == 400, 'failed target retried')
    local leg = state.leg
    game.tick = game.tick + escort.LEG_TIMEOUT + 1
    escort.tick()
    assert(state.leg ~= leg, 'stuck leg never timed out')
  end)

  test('escort offensive: charting uses the division centroid', function()
    setup()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 320, 320)
    divisions.assign(1, 3, {a})
    band_surface(game.surfaces[1], {})
    escort.start(1, 3, 2, 'offensive')
    settle()
    local force = game.players[1].force
    assert(force.is_chunk_charted(game.surfaces[1], {x = 10, y = 10}), 'area around the division not charted')
  end)

  test('escort settings: a changed ring radius re-spaces the ring and redraws its marker', function()
    setup()
    dofile('control.lua')
    local handlers = ctx.handlers()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 10, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    settle()
    assert(math.abs(geometry.distance(a.command.destination, {x = 0, y = 0}) - 160) < 1e-6, 'default ring is not 160')
    settings.global['tank-squads-escort-ring-radius'] = {value = 200}
    handlers.on_runtime_mod_setting_changed{setting = 'tank-squads-escort-ring-radius', setting_type = 'runtime-global'}
    local before = #ctx.draws()
    escort.tick()
    assert(math.abs(geometry.distance(a.command.destination, {x = 0, y = 0}) - 200) < 1e-6, 'ring kept the old radius')
    local redrawn = false
    for i = before + 1, #ctx.draws() do
      if ctx.draws()[i].args.radius == 200 then redrawn = true end
    end
    assert(redrawn, 'ring marker not redrawn at the new radius')
  end)

  test('escort settings: a changed band ends the offensive leg; other settings do nothing', function()
    local surface = setup()
    dofile('control.lua')
    local handlers = ctx.handlers()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 5, 0)
    divisions.assign(1, 3, {a})
    band_surface(surface, {})
    escort.start(1, 3, 2, 'offensive')
    settle()
    local state = divisions.record(1, 3).escort
    local first = state.leg
    handlers.on_runtime_mod_setting_changed{setting = 'another-mod-setting', setting_type = 'runtime-global'}
    assert(state.leg == first, 'an unrelated setting ended the leg')
    settings.global['tank-squads-escort-band-min'] = {value = 500}
    settings.global['tank-squads-escort-band-max'] = {value = 600}
    handlers.on_runtime_mod_setting_changed{setting = 'tank-squads-escort-band-min', setting_type = 'runtime-global'}
    escort.tick()
    assert(state.leg ~= first, 'offensive leg kept after the band changed')
    local d = geometry.distance(state.leg.destination, {x = 0, y = 0})
    assert(d >= 500 and d <= 600, 'new leg outside the new band: ' .. d)
  end)

  test('escort settings: an escort from an older save re-spaces onto the new ring on upgrade', function()
    setup()
    game.players[1].force.technologies = {}
    game.forces = {player = game.players[1].force}
    dofile('control.lua')
    local handlers = ctx.handlers()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 10, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    settle()
    local state = divisions.record(1, 3).escort
    -- 0.7.x saved slots without the radius they were assigned for.
    state.ring = nil
    a.command = nil
    handlers.configuration_changed{}
    escort.tick()
    assert(a.command and math.abs(geometry.distance(a.command.destination, {x = 0, y = 0}) - 160) < 1e-6,
      'old escort not re-spaced after upgrade')
  end)

  local retreat = require('scripts.retreat')

  local function depot(x, y)
    local b = ctx.building()
    b.position = {x = x, y = y}
    return b
  end

  test('escort retreat: an injured defender leaves the ring, which re-spaces, and returns healed', function()
    setup()
    ward_player(2, 0, 0)
    depot(30, 0)
    local a, b = soldier(nil, nil, 10, 0), soldier(nil, nil, -10, 0)
    divisions.assign(1, 3, {a, b})
    escort.start(1, 3, 2, 'defensive')
    settle()
    local state = divisions.record(1, 3).escort
    a.health = 60
    escort.tick()
    assert(a.command.destination.x == 30, 'injured soldier not sent to the barracks')
    assert(state.slots[a.unit_number] == nil, 'injured soldier kept a ring slot')
    assert(math.abs(geometry.distance(b.command.destination, {x = 0, y = 0}) - 160) < 1e-6, 'ring did not re-space')
    state.responders = {[a.unit_number] = b}
    assert(escort.on_command_completed(a.unit_number, defines.behavior_result.success))
    assert(state.responders[a.unit_number] == b, 'a completion from an away soldier changed the responders')
    state.responders = nil
    a.health = 400
    escort.tick()
    assert(state.slots[a.unit_number], 'healed soldier got no slot')
    assert(math.abs(geometry.distance(a.command.destination, {x = 0, y = 0}) - 160) < 1e-6,
      'healed soldier did not return to the ring')
  end)

  test('escort retreat: an offensive leg ends when its leader retreats; a returning soldier joins the leg', function()
    local surface = setup()
    ward_player(2, 0, 0)
    depot(30, 0)
    local a, b = soldier(nil, nil, 5, 0), soldier(nil, nil, 6, 0)
    divisions.assign(1, 3, {a, b})
    band_surface(surface, {})
    escort.start(1, 3, 2, 'offensive')
    settle()
    local state = divisions.record(1, 3).escort
    assert(state.leg.leader == a.unit_number, 'test setup: a does not lead')
    local first = state.leg
    a.health = 60
    escort.tick()
    assert(state.leg ~= first and state.leg.leader == b.unit_number, 'leg kept an away leader')
    assert(a.command.destination.x == 30, 'leader not sent to the barracks')
    a.health = 400
    escort.tick()
    assert(a.command == state.leg.command, 'returning soldier did not join the current leg')
  end)

  test('escort retreat: a fully retreated division waits and keeps its ward panel entry', function()
    setup()
    ward_player(2, 0, 0)
    depot(30, 0)
    local a = soldier(nil, nil, 10, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'defensive')
    settle()
    a.health = 60
    escort.tick()
    local wards = escort.wards()
    assert(retreat.is_away(divisions.record(1, 3).escort, a.unit_number), 'lone soldier did not retreat')
    assert(wards[2] and #wards[2] == 1, 'escort hidden from the ward panel while everyone is away')
    escort.tick()
    wards = escort.wards()
    assert(wards[2] and #wards[2] == 1, 'second sweep with nobody present failed')
  end)

  test('escort retreat: completions from away soldiers reach the retreat', function()
    setup()
    ward_player(2, 0, 0)
    depot(30, 0)
    local a, b = soldier(nil, nil, 10, 0), soldier(nil, nil, -10, 0)
    divisions.assign(1, 3, {a, b})
    escort.start(1, 3, 2, 'defensive')
    settle()
    a.health = 60
    escort.tick()
    a.position, a.command = {x = 80, y = 0}, nil
    assert(escort.on_command_completed(a.unit_number, defines.behavior_result.success))
    escort.tick()
    assert(a.command and a.command.destination.x == 30, 'displaced soldier not sent back to the barracks')
  end)

  test('escort retreat: switching or stopping the escort drops every convoy', function()
    setup()
    ward_player(2, 0, 0)
    depot(30, 0)
    local a, b = soldier(nil, nil, 10, 0), soldier(nil, nil, -10, 0)
    divisions.assign(1, 3, {a, b})
    escort.start(1, 3, 2, 'defensive')
    settle()
    a.health = 60
    escort.tick()
    assert(retreat.is_away(divisions.record(1, 3).escort, a.unit_number))
    escort.start(1, 3, 2, 'offensive')
    assert(divisions.record(1, 3).escort.retreat == nil, 'formation switch kept the convoy')
    escort.stop(1, 3)
    assert(divisions.record(1, 3).escort == nil)
  end)

  local barracks = require('scripts.barracks')

  test('escort wiring: map markers are private, cheap and follow the formation', function()
    setup()
    ward_player(2, 0, 0)
    divisions.assign(1, 3, {soldier(nil, nil, 5, 0)})
    escort.start(1, 3, 2, 'defensive')
    local before = #ctx.draws()
    settle()
    local ring, label
    for i = before + 1, #ctx.draws() do
      local d = ctx.draws()[i]
      if d.args.radius == 160 then ring = d end
      if d.args.text == '3 DEF' then label = d end
    end
    assert(ring and ring.args.render_mode == 'chart', 'no defensive map ring')
    assert(#ring.args.players == 2 and ring.args.players[2] == 2, 'ring not private to owner and ward')
    assert(label and label.args.target.entity == game.players[2].character, 'no ward label')
    local count = #ctx.draws()
    escort.tick()
    assert(#ctx.draws() == count, 'markers redrawn without an anchor move')
    escort.start(1, 3, 2, 'offensive')
    escort.tick()
    assert(not ring.valid, 'defensive ring survived formation switch')
    local dashed = 0
    for i = count + 1, #ctx.draws() do
      if ctx.draws()[i].valid and ctx.draws()[i].args.dash_length then dashed = dashed + 1 end
    end
    assert(dashed > 0, 'offensive band not drawn')
    escort.stop(1, 3)
    for i = before + 1, #ctx.draws() do
      local d = ctx.draws()[i]
      assert(not (d.valid and (d.args.dash_length or d.args.text == '3 OFF')), 'marker survived stop')
    end
  end)

  test('escort wiring: a reinforcement joins the ring or the current leg', function()
    setup()
    ward_player(2, 0, 0)
    divisions.assign(1, 3, {soldier(nil, nil, 5, 0)})
    escort.start(1, 3, 2, 'defensive')
    settle()
    local b, output = ctx.building()
    assert(barracks.configure(b, 1, 3, 2))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    escort.tick()
    local members = divisions.get(1, 3)
    assert(#members == 2)
    local recruit = members[2]
    assert(recruit.command and recruit.command.type == defines.command.go_to_location, 'recruit got no slot')
    assert(math.abs(geometry.distance(recruit.command.destination, {x = 0, y = 0}) - 160) < 1e-6)
  end)

  test('escort wiring: control routes completions and removes escorts of removed wards', function()
    setup()
    dofile('control.lua')
    local handlers = ctx.handlers()
    ward_player(2, 0, 0)
    local a = soldier(nil, nil, 5, 0)
    divisions.assign(1, 3, {a})
    escort.start(1, 3, 2, 'offensive')
    game.surfaces[1].find_entities_filtered = function() return {} end
    settle()
    local state = divisions.record(1, 3).escort
    handlers.on_ai_command_completed{unit_number = a.unit_number, result = defines.behavior_result.success}
    assert(state.leg == nil, 'completion not routed to escort')
    game.players[2] = nil
    handlers.on_player_removed{player_index = 2}
    assert(divisions.record(1, 3).escort == nil, 'removed ward kept escort')
  end)

  test('escort wiring: the sliced sweep builds the ward list once per second', function()
    setup()
    dofile('control.lua')
    local sweep = ctx.handlers().nth_tick
    ward_player(2, 0, 0)
    divisions.assign(1, 3, {soldier(nil, nil, 5, 0)})
    escort.start(1, 3, 2, 'defensive')
    local wards, builds = escort.wards, 0
    escort.wards = function() builds = builds + 1; return wards() end
    for tick = 0, 60 - sweep.period, sweep.period do
      game.tick = tick
      sweep.handler{tick = tick}
    end
    escort.wards = wards
    assert(builds == 1, 'ward list built ' .. builds .. ' times in one second')
  end)

  local escort_gui

  local function gui_setup()
    setup()
    escort_gui = require('scripts.escort_gui')
    game.players[1].name, game.players[1].connected = 'owner', true
    game.players[1].gui.screen = ctx.gui_element()
    game.players[1].gui.left = ctx.gui_element()
  end

  test('escort gui: ward list puts connected teammates first and excludes other forces', function()
    gui_setup()
    local zed = ward_player(2, 0, 0); zed.name, zed.connected = 'zed', true
    local amy = ward_player(3, 0, 0); amy.name, amy.connected = 'amy', false
    local bob = ward_player(4, 0, 0); bob.name, bob.connected = 'bob', true
    local foe = ward_player(5, 0, 0); foe.name, foe.connected, foe.force = 'foe', true, {}
    local list = escort_gui.ward_options(game.players[1])
    assert(table.concat(list, ',') == '4,1,2,3', 'wrong order: ' .. table.concat(list, ','))
  end)

  test('escort gui: window starts, switches and stops the selected division', function()
    gui_setup()
    ward_player(2, 0, 0).connected = true
    divisions.assign(1, 3, {soldier()})
    escort_gui.toggle(1)
    local frame = game.players[1].gui.screen.tank_squads_escort
    assert(frame and frame.valid, 'window not opened')
    frame.body.ward.selected_index = 2
    assert(escort_gui.click{player_index = 1, element = frame.body.actions.defensive})
    local record = divisions.record(1, 3)
    assert(record.escort and record.escort.ward == 2 and record.escort.formation == 'defensive')
    assert(escort_gui.click{player_index = 1, element = frame.body.actions.stop})
    assert(record.escort == nil)
  end)

  test('escort gui: division 0 gets an explanation instead of controls', function()
    gui_setup()
    divisions.select_area(1, {soldier()})
    escort_gui.toggle(1)
    local frame = game.players[1].gui.screen.tank_squads_escort
    assert(frame.body.hint and not frame.body.actions, 'division 0 offered escort controls')
  end)

  test('escort gui: ward panel lists foreign escorts with a working dismiss', function()
    gui_setup()
    local ward = ward_player(2, 0, 0)
    ward.connected = true
    divisions.assign(1, 3, {soldier()})
    escort.start(1, 3, 2, 'offensive')
    escort.tick(); escort_gui.update_wards(escort.wards())
    local frame = ward.gui.left.tank_squads_escorts
    assert(frame and frame.visible, 'ward panel missing')
    local button = frame.rows.children[1].dismiss
    assert(escort_gui.click{player_index = 2, element = button})
    assert(divisions.record(1, 3).escort == nil, 'dismiss did not end escort')
    escort.tick(); escort_gui.update_wards(escort.wards())
    assert(not frame.visible, 'empty ward panel still visible')
  end)

  test('escort gui: division caption shows ward, formation and waiting', function()
    gui_setup()
    local ward = ward_player(2, 0, 0)
    divisions.assign(1, 3, {soldier()})
    escort.start(1, 3, 2, 'defensive')
    escort.tick()
    require('scripts.panel').update(1)
    local caption = game.players[1].gui.left.tank_squads_divisions.divisions.division_3.caption
    assert(caption[5][1] == 'tank-squads.mode-escort' and caption[5][2] == ward.name, 'escort caption missing')
    assert(caption[5][3][1] == 'tank-squads.formation-defensive')
    ward.character = nil
    escort.tick()
    require('scripts.panel').update(1)
    caption = game.players[1].gui.left.tank_squads_divisions.divisions.division_3.caption
    assert(caption[5][3][1] == 'tank-squads.formation-waiting', 'waiting state not shown')
  end)
end
