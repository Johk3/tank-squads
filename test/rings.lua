return function(ctx)
  local test = ctx.test
  local names = require('scripts.names')
  local geometry = require('scripts.engineers.rings.geometry')

  local function square(radius)
    return {shape = 'square', centre = {x = 0, y = 0}, radius = radius, bulges = {}}
  end

  local function circle(radius)
    return {shape = 'circle', centre = {x = 0, y = 0}, radius = radius, bulges = {}}
  end

  test('rings: gate spacing shrinks with radius in steps of 16', function()
    local want = {[100] = 128, [200] = 128, [400] = 112, [600] = 96, [800] = 80, [1000] = 64, [2000] = 64}
    for radius, spacing in pairs(want) do
      assert(geometry.spacing(radius) == spacing, radius .. ': ' .. geometry.spacing(radius))
    end
  end)

  test('rings: a square has one segment per gatehouse', function()
    assert(geometry.segment_count(square(100)) == 4)
    assert(geometry.segment_count(square(200)) == 12)
    assert(geometry.segment_count(square(600)) == 44)
  end)

  test('rings: square segments cover each side from corner to corner', function()
    local ring = square(200)
    local first, last = geometry.side_range(200)
    for side = 1, 4 do
      local expect = first
      for k = 1, 3 do
        local seg = geometry.segment(ring, (side - 1) * 3 + k)
        assert(seg.side == side and seg.lo == expect, 'gap before segment ' .. k .. ' of side ' .. side)
        assert(seg.gate - geometry.HOUSE_HALF >= seg.lo and seg.gate + geometry.HOUSE_HALF - 1 <= seg.hi,
          'gatehouse leaves its segment')
        expect = seg.hi + 1
      end
      assert(expect == last + 1, 'side ' .. side .. ' does not end at its corner')
    end
  end)

  test('rings: the outer gatehouses keep 24 tiles from the corner bastions', function()
    for _, radius in ipairs({100, 200, 333, 600, 1000}) do
      local ring = square(radius)
      local per = geometry.segment_count(ring) / 4
      local last, first = geometry.segment(ring, per), geometry.segment(ring, 1)
      assert(last.gate + geometry.HOUSE_HALF - 1 <= radius - 1 - 24, 'radius ' .. radius .. ' end')
      assert(first.gate - geometry.HOUSE_HALF >= -(radius - 2) + 24, 'radius ' .. radius .. ' start')
    end
  end)

  test('rings: segment_of finds the segment holding an along position', function()
    for _, ring in ipairs({square(200), square(600)}) do
      for i = 1, geometry.segment_count(ring) do
        local seg = geometry.segment(ring, i)
        for _, a in ipairs({seg.gate, seg.lo, seg.hi}) do
          assert(geometry.segment_of(ring, seg.side, a) == i, 'square ' .. i .. ' at ' .. a)
        end
      end
    end
    local ring = circle(300)
    local C = geometry.TAU * 300
    for i = 1, geometry.segment_count(ring) do
      local seg = geometry.segment(ring, i)
      for _, a in ipairs({seg.gate, seg.lo + 0.01, seg.hi - 0.01}) do
        assert(geometry.segment_of(ring, 0, a % C) == i, 'circle ' .. i .. ' at ' .. a)
      end
    end
  end)

  test('rings: square frames map tiles and back on every side', function()
    local ring = square(200)
    for side = 1, 4 do
      for _, p in ipairs({{0, 0}, {-150, 2}, {150, -1}, {198, 4}, {202, 3}}) do
        local x, y = geometry.to_tile(ring, side, p[1], p[2])
        local s, a, d = geometry.to_frame(ring, x + 0.5, y + 0.5)
        assert(s == side and a == p[1] and d == p[2],
          ('side %d (%d, %d) came back as %d (%d, %d)'):format(side, p[1], p[2], s, a, d))
      end
    end
  end)

  test('rings: side tells inside from outside, and the band', function()
    local ring = square(200)
    assert(geometry.side(ring, 10.5, 10.5) == 'inside')
    assert(geometry.side(ring, 260.5, 0.5) == 'outside')
    assert(geometry.side(ring, 900.5, 900.5) == 'outside')
    assert(select(2, geometry.side(ring, 200.5, 5.5)), 'the middle wall row is not on the band')
    assert(not select(2, geometry.side(ring, 190.5, 5.5)), 'ten tiles inside counts as band')
    assert(geometry.in_band(ring, 197.5, 0.5) and geometry.in_band(ring, 204.5, 0.5))
    assert(not geometry.in_band(ring, 205.5, 0.5))
    ring.bulges = {{side = 1, a0 = -10, a1 = 10, depth = 20, kind = 'bulge'}}
    assert(geometry.side(ring, 210.5, 0.5) == 'inside', 'a bulge did not push the wall out')
    assert(geometry.side(ring, 230.5, 0.5) == 'outside')
    assert(select(2, geometry.side(ring, 220.5, 0.5)), 'the bulge front is not on the band')
  end)

  test('rings: the interior is the enclosed area off the band', function()
    for _, ring in ipairs({square(200), circle(200)}) do
      assert(geometry.interior(ring, 0.5, 0.5) and geometry.interior(ring, 150.5, -20.5))
      assert(not geometry.interior(ring, 199.5, 0.5), 'the band counted as inside')
      assert(not geometry.interior(ring, 260.5, 0.5), 'outside counted as inside')
    end
    assert(geometry.interior(square(200), 180.5, 180.5) and not geometry.interior(circle(200), 180.5, 180.5))
    local x0, y0, x1, y1 = geometry.interior_chunks(square(200))
    assert(x0 == -7 and y0 == -7 and x1 == 6 and y1 == 6, x0 .. ',' .. y0 .. ',' .. x1 .. ',' .. y1)
  end)

  test('rings: a circle frame measures along clockwise from north', function()
    local ring = circle(300)
    local side, a, d = geometry.to_frame(ring, 0.5, -299.5)
    assert(side == 0 and math.abs(a) < 1e-6 and math.abs(d) < 1e-6)
    local _, east = geometry.to_frame(ring, 300.5, 0.5)
    assert(math.abs(east - math.pi / 2 * 300) < 1e-6)
    assert(geometry.side(ring, 0.5, 0.5) == 'inside' and geometry.side(ring, 400.5, 0.5) == 'outside')
  end)

  test('rings: circle gatehouses are axis-aligned blocks', function()
    local ring = circle(300)
    local north = geometry.circle_house(ring, 0)
    assert(north.dir == 'north' and north.ux == 1 and north.ny == -1)
    local east = geometry.circle_house(ring, geometry.TAU * 300 / 4)
    assert(east.dir == 'east' and east.uy == 1 and east.nx == 1)
  end)

  test('rings: aprons stand 9 tiles inside and 10 outside the gatehouse', function()
    local ring = square(200)
    local seg = geometry.segment(ring, 2)
    local inside, outside = geometry.apron(ring, seg, 'inside'), geometry.apron(ring, seg, 'outside')
    assert(inside.x == 191.5 and inside.y == 0.5, inside.x .. ',' .. inside.y)
    assert(outside.x == 210.5 and outside.y == 0.5, outside.x .. ',' .. outside.y)
  end)

  test('rings: order runs round the ring segment by segment', function()
    local ring = square(200)
    local a = geometry.order(ring, 200.5, -150.5)
    local b = geometry.order(ring, 200.5, 150.5)
    local c = geometry.order(ring, 0.5, 200.5)
    assert(a < b and b < c, a .. ' ' .. b .. ' ' .. c)
  end)

  local layout = require('scripts.engineers.rings.layout')

  local function by_tile(tiles)
    local map = {}
    for _, t in ipairs(tiles) do map[math.floor(t.x) .. ',' .. math.floor(t.y)] = t end
    return map
  end

  -- The planned tile at a frame position, or nil.
  local function at(ring, map, side, a, d)
    local x, y = geometry.to_tile(ring, side, a, d)
    return map[x .. ',' .. y]
  end

  test('rings: a square segment has three wall rows, a gap and checkerboard teeth', function()
    local ring = square(200)
    local map = by_tile(layout.plan(ring, 1, {}))
    local a = -175
    for d = -1, 1 do assert(at(ring, map, 1, a, d).name == 'stone-wall', 'wall row ' .. d) end
    assert(not at(ring, map, 1, a, 2), 'the gap row holds a wall')
    for d = 3, 4 do
      local x, y = geometry.to_tile(ring, 1, a, d)
      assert((at(ring, map, 1, a, d) ~= nil) == ((x + y) % 2 == 0), 'teeth off the checkerboard in row ' .. d)
    end
    assert(not at(ring, map, 1, a, -2) and not at(ring, map, 1, a, 5))
  end)

  test('rings: a gatehouse is one row of 16 gates, flanked by bastions, lane clear', function()
    local ring = square(200)
    local tiles = layout.plan(ring, 2, {})
    local map = by_tile(tiles)
    local gates = 0
    for _, t in ipairs(tiles) do
      if t.name == 'gate' then
        gates = gates + 1
        assert(t.dir == 'east', 'a gate in an east wall faces ' .. t.dir)
      end
    end
    assert(gates == 16, gates .. ' gates')
    for u = -8, 7 do
      assert(at(ring, map, 1, u, 0).name == 'gate', 'gate missing at ' .. u)
      for _, d in ipairs({-3, -2, -1, 1, 2, 3, 4}) do
        assert(not at(ring, map, 1, u, d), 'lane blocked at ' .. u .. ',' .. d)
      end
    end
    for _, u in ipairs({-14, -9, 8, 13}) do
      for d = -3, 4 do assert(at(ring, map, 1, u, d).name == 'stone-wall', 'bastion hole at ' .. u .. ',' .. d) end
    end
  end)

  test('rings: plain bastions stand every 32 tiles clear of gatehouses', function()
    local ring = square(200)
    local map = by_tile(layout.plan(ring, 1, {}))
    for a = -161, -158 do
      for d = 1, 4 do assert(at(ring, map, 1, a, d), 'bastion hole at ' .. a .. ',' .. d) end
    end
    assert(not at(ring, map, 1, -165, 2), 'wall in the gap row away from a bastion')
  end)

  test('rings: each side ends in a solid 6 by 6 corner', function()
    local ring = square(200)
    local map = by_tile(layout.plan(ring, 3, {}))
    for a = 199, 204 do
      for d = -1, 4 do assert(at(ring, map, 1, a, d), 'corner hole at ' .. a .. ',' .. d) end
    end
  end)

  test('rings: a whole square ring has a closed inner wall and no tile twice', function()
    local ring = square(200)
    local tiles, seen = {}, {}
    for i = 1, geometry.segment_count(ring) do
      for _, t in ipairs(layout.plan(ring, i, {})) do
        local key = math.floor(t.x) .. ',' .. math.floor(t.y)
        assert(not seen[key], 'tile planned twice: ' .. key)
        seen[key] = true
        tiles[#tiles + 1] = t
      end
    end
    local map = by_tile(tiles)
    for side = 1, 4 do
      for a = -198, 204 do
        local gate = at(ring, map, side, a, 0)
        assert(at(ring, map, side, a, -1) or (gate and gate.name == 'gate'),
          'inner wall open at side ' .. side .. ' along ' .. a)
      end
    end
  end)

  test('rings: a circle segment keeps walls on the band and gates in one straight row', function()
    local ring = circle(300)
    local gates, rows = 0, {}
    for _, t in ipairs(layout.plan(ring, 1, {})) do
      if t.name == 'gate' then
        gates = gates + 1
        local y = math.floor(t.y)
        rows[y] = (rows[y] or 0) + 1
        assert(t.dir == 'north')
      else
        local _, _, d = geometry.to_frame(ring, t.x, t.y)
        assert(d > -5 and d < 6, 'wall off the band at depth ' .. d)
      end
    end
    assert(gates == 16, gates .. ' gates')
    for y, n in pairs(rows) do assert(n == 16, 'gate row ' .. y .. ' has ' .. n) end
  end)

  -- Every planned tile's standing spots, inside and outside: on that side
  -- of the ring, and no planned tile under the constructor's hull.
  local function check_stands(ring, count)
    local tiles = {}
    for i = 1, count or geometry.segment_count(ring) do
      for _, t in ipairs(layout.plan(ring, i, {})) do tiles[#tiles + 1] = t end
    end
    local map = by_tile(tiles)
    for _, t in ipairs(tiles) do
      for _, where in ipairs({'inside', 'outside'}) do
        local p = geometry.stand(ring, t.x, t.y, where)
        local side = geometry.side(ring, p.x, p.y)
        assert(side == where, where .. ' stand for ' .. t.x .. ',' .. t.y .. ' is ' .. side)
        for x = math.floor(p.x - 0.9), math.floor(p.x + 0.9) do
          for y = math.floor(p.y - 0.9), math.floor(p.y + 0.9) do
            assert(not map[x .. ',' .. y], where .. ' stand for ' .. t.x .. ',' .. t.y .. ' is on a wall at ' .. x .. ',' .. y)
          end
        end
      end
    end
  end

  test('rings: a constructor stands off the band on its own side of a square', function()
    check_stands(square(200))
  end)

  test('rings: a constructor stands off the band on its own side of a circle', function()
    check_stands(circle(300))
  end)

  test('rings: a constructor stands in the pocket or beyond the legs of a bulge', function()
    local ring = square(200)
    ring.bulges = {{side = 1, a0 = -180, a1 = -170, depth = 20, kind = 'bulge'}}
    check_stands(ring, 1)
    local p = geometry.stand(ring, 220.5, -175.5, 'inside')
    local _, a, d = geometry.to_frame(ring, p.x, p.y)
    assert(a >= -180 and a <= -170 and d == 15, 'front stand at ' .. a .. ',' .. d)
  end)

  test('rings: a bulge carries the full wall round an obstacle', function()
    local ring = square(200)
    local o = {bulges = {{side = 1, a0 = -180, a1 = -170, depth = 20, kind = 'bulge'}}}
    local map = by_tile(layout.plan(ring, 1, o))
    for d = -1, 1 do assert(not at(ring, map, 1, -175, d), 'old wall line kept inside the bulge') end
    for d = 19, 21 do assert(at(ring, map, 1, -175, d), 'bulge front missing in row ' .. d) end
    for d = -1, 21 do assert(at(ring, map, 1, -182, d), 'leg gap in row ' .. d) end
    for d = 21, 24 do assert(at(ring, map, 1, -180, d), 'bulge corner bastion missing in row ' .. d) end
  end)

  test('rings: a bulge too long or deep ends the wall against the obstacle', function()
    local ring = square(200)
    local o = {bulges = {{side = 1, a0 = -180, a1 = -170, depth = 90, kind = 'end'}}}
    local map = by_tile(layout.plan(ring, 1, o))
    for a = -180, -170 do
      for d = -3, 6 do assert(not at(ring, map, 1, a, d), 'wall through the obstacle at ' .. a .. ',' .. d) end
    end
    for d = -1, 2 do assert(at(ring, map, 1, -181, d) and at(ring, map, 1, -169, d), 'end bastion missing') end
  end)

  test('rings: obstacle boxes that reach the wall merge into bulges', function()
    local boxes = {{a0 = 0, a1 = 10, d0 = -2, d1 = 8}, {a0 = 12, a1 = 20, d0 = 0, d1 = 12},
      {a0 = 60, a1 = 70, d0 = -40, d1 = -10}}
    local out = layout.bulges(boxes, {}, 1, 70)
    assert(#out == 1, #out .. ' bulges')
    assert(out[1].a0 == 0 and out[1].a1 == 20 and out[1].depth == 14 and out[1].kind == 'bulge' and out[1].side == 1)
    assert(layout.bulges({{a0 = 0, a1 = 200, d0 = 0, d1 = 5}}, {}, 1, 70)[1].kind == 'end', 'too long')
    assert(layout.bulges({{a0 = 0, a1 = 10, d0 = 0, d1 = 69}}, {}, 1, 70)[1].kind == 'end', 'too deep')
    local stored = {{side = 1, a0 = 5, a1 = 30, depth = 10, kind = 'bulge'}}
    assert(#layout.bulges(boxes, stored, 1, 70) == 0, 'a stored bulge was made twice')
  end)

  test('rings: a straight rail crossing gets gates, a belt a gap', function()
    local ring = square(200)
    local o = {crossings = {{side = 1, a0 = -176, a1 = -175, rail = true}, {side = 1, a0 = -110, a1 = -110, rail = false}}}
    local map = by_tile(layout.plan(ring, 1, o))
    assert(at(ring, map, 1, -176, 0).name == 'gate', 'rail gate missing')
    for _, d in ipairs({-1, 1}) do assert(not at(ring, map, 1, -176, d), 'rail gate doubled in row ' .. d) end
    for d = 3, 4 do assert(not at(ring, map, 1, -176, d), 'teeth on the rail') end
    for d = -3, 6 do assert(not at(ring, map, 1, -110, d), 'belt gap closed in row ' .. d) end
  end)

  test('rings: crossings merge where they touch', function()
    local out = layout.crossings({{side = 1, a0 = 5, a1 = 6, rail = true}, {side = 1, a0 = 7, a1 = 7, rail = false},
      {side = 2, a0 = 5, a1 = 5, rail = false}})
    assert(#out == 2 and out[1].a0 == 5 and out[1].a1 == 7 and out[1].rail == false)
  end)

  test('rings: water tiles stay empty and a gatehouse in water is left out', function()
    local ring = square(200)
    local water = {}
    for d = -3, 6 do
      local x, y = geometry.to_tile(ring, 1, 0, d)
      water[x .. ',' .. y] = true
    end
    local tiles = layout.plan(ring, 2, {water = water})
    local map = by_tile(tiles)
    for d = -3, 6 do assert(not at(ring, map, 1, 0, d), 'wall in water') end
    for _, t in ipairs(tiles) do assert(t.name ~= 'gate', 'gatehouse built next to water') end
  end)

  test('rings: gate direction follows the wall line', function()
    local ring = square(200)
    assert(layout.gate_dir(ring, 200.5, 0.5) == 'east')
    assert(layout.gate_dir(ring, 0.5, 200.5) == 'north')
    assert(layout.gate_dir(circle(300), 0.5, -299.5) == 'north')
  end)

  -- A world where rings can be started and ghosts placed, outside the engine.
  local function ring_world()
    local state = require('scripts.engineers.state')
    local s = state.get()
    s.scanned[1] = true
    local surface = game.surfaces[1]
    local force = game.forces[1]
    force.printed = {}
    force.print = function(message) force.printed[#force.printed + 1] = message end
    force.get_spawn_position = function() return {x = 0, y = 0} end
    surface.create_entity = function(spec)
      local g = ctx.soldier(nil, nil, spec.position.x, spec.position.y)
      g.name, g.type, g.ghost_name, g.direction = 'entity-ghost', 'entity-ghost', spec.inner_name, spec.direction
      g.force_index, g.surface_index = 1, 1
      g.destroy = function() g.valid = false end
      return g
    end
    surface.find_non_colliding_position = function(_, position) return {x = position.x, y = position.y} end
    defines.direction = {north = 0, east = 4, south = 8, west = 12}
    defines.build_check_type = {manual_ghost = 3}
    return require('scripts.engineers.rings.rings'), s, surface, force
  end

  test('rings: settings are clamped, and each change bumps the version', function()
    local rings = ring_world()
    assert(rings.set(1, 'spacing', 50) == 100 and rings.set(1, 'spacing', 5000) == 1000)
    assert(rings.set(1, 'spacing', 'abc') == 1000, 'text changed the spacing')
    assert(rings.set(1, 'count', 0) == 1 and rings.set(1, 'count', 7.6) == 7)
    assert(rings.set(1, 'shape', 'hexagon') == 'square' and rings.set(1, 'shape', 'circle') == 'circle')
    assert(rings.version(1) == 5, 'version ' .. rings.version(1))
  end)

  test('rings: a ring starts round the spawn with four map labels', function()
    local rings, _, surface, force = ring_world()
    local fs = rings.force_state(1)
    local before = #ctx.draws()
    local ring = rings.start(fs, force, 1, surface)
    assert(ring.radius == 200 and ring.centre.x == 0 and ring.state == 'building')
    assert(ring.count == 12 and ring.segments[12].state == 'unplanned')
    assert(#ctx.draws() - before == 4 and #ring.labels == 4)
    assert(rings.by_key(ring.key) == ring)
  end)

  test('rings: a new ring keeps clear of the one before', function()
    local rings, _, surface, force = ring_world()
    local fs = rings.force_state(1)
    rings.start(fs, force, 1, surface)
    rings.set(1, 'spacing', 100)
    local second = rings.start(fs, force, 2, surface)
    assert(second.radius == 280, 'ring 2 at radius ' .. second.radius)
  end)

  test('rings: the current ring is the lowest slot with segments left to plan', function()
    local rings, _, surface, force = ring_world()
    local fs = rings.force_state(1)
    local first = rings.start(fs, force, 1, surface)
    assert(rings.current(fs, force, surface) == first)
    for _, seg in ipairs(first.segments) do seg.state = 'placed' end
    local second = rings.current(fs, force, surface)
    assert(second and second.n == 2, 'slot 2 was not started')
    second.state = 'deleted'
    assert(rings.current(fs, force, surface).n == 3, 'a deleted slot was worked on')
    rings.set(1, 'count', 2)
    assert(rings.current(fs, force, surface) == nil, 'worked past the ring count')
  end)

  test('rings: a generating segment waits for its delay, then anyone takes it', function()
    local rings, _, surface, force = ring_world()
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    for i = 1, ring.count do ring.segments[i].state = 'placed' end
    ring.segments[5].state, ring.segments[5].due = 'generating', 100
    game.tick = 50
    assert(rings.next_segment(ring, {x = 0, y = 0}, game.tick) == nil)
    assert(rings.waiting(ring, game.tick), 'a generating segment does not count as work to wait for')
    game.tick = 100
    assert(rings.next_segment(ring, {x = 0, y = 0}, game.tick) == 5)
  end)

  test('rings: the next segment is the unplanned one nearest the constructor', function()
    local rings, _, surface, force = ring_world()
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    assert(rings.next_segment(ring, {x = 250, y = 0}, 0) == 2)
    assert(rings.next_segment(ring, {x = 0, y = -250}, 0) == 11)
  end)

  test('rings: placed ghosts are tagged and counted, and the last one built finishes the segment', function()
    local rings, s, surface, force = ring_world()
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    local built, saved = {}, rings.on_segment_built
    rings.on_segment_built = function(r, i) built[#built + 1] = i end
    ring.segments[1].state = 'placed'
    rings.place(ring, 1, {{x = 200.5, y = -150.5, name = 'stone-wall', dir = 'east', a = -151},
      {x = 201.5, y = -150.5, name = 'gate', dir = 'east', a = -151}}, surface, force)
    local seg = ring.segments[1]
    assert(seg.live == 2, seg.live .. ' live')
    local ids = {}
    for id in pairs(seg.ghosts) do ids[#ids + 1] = id; assert(s.ring_ghosts[id].ring == ring.key) end
    assert(require('scripts.engineers.ghosts').bucket(1, 1).count == 2, 'ghosts not in the registry')
    rings.ghost_gone(ids[1], {x = 200.5, y = -150.5}, true)
    assert(seg.live == 1 and seg.state == 'placed')
    rings.ghost_gone(ids[2], {x = 201.5, y = -150.5}, true)
    rings.on_segment_built = saved
    assert(seg.state == 'built' and built[1] == 1)
  end)

  test('rings: a ghost gone with no wall on its tile releases the tile', function()
    local rings, _, surface, force = ring_world()
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    ring.segments[1].state = 'placed'
    rings.place(ring, 1, {{x = 200.5, y = -150.5, name = 'stone-wall', dir = 'east', a = -151},
      {x = 200.5, y = -149.5, name = 'stone-wall', dir = 'east', a = -150}}, surface, force)
    local ids = {}
    for id in pairs(ring.segments[1].ghosts) do ids[#ids + 1] = id end
    table.sort(ids)
    rings.ghost_gone(ids[1], {x = 200.5, y = -150.5}, false)
    assert(ring.released['200,-151'], 'a removed ghost was not released')
    local wall = ctx.soldier(nil, nil, 200.5, -149.5)
    wall.type = 'wall'
    rings.ghost_gone(ids[2], {x = 200.5, y = -149.5}, false)
    assert(not ring.released['200,-150'], 'a tile with a wall on it was released')
    rings.place(ring, 1, {{x = 200.5, y = -150.5, name = 'stone-wall', dir = 'east', a = -151}}, surface, force)
    assert(ring.segments[1].live == 0, 'a released tile got a new ghost')
  end)

  test('rings: a segment with nothing to place is built at once', function()
    local rings, _, surface, force = ring_world()
    local obstacles = require('scripts.engineers.rings.obstacles')
    local layout = require('scripts.engineers.rings.layout')
    local scan, plan = obstacles.scan, layout.plan
    obstacles.scan = function() return {bulges = {}, crossings = {}, water = {}} end
    layout.plan = function() return {} end
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    local ok, result = pcall(rings.plan_segment, ring, 3)
    obstacles.scan, layout.plan = scan, plan
    assert(ok, result)
    assert(result == 'built' and ring.segments[3].state == 'built', tostring(result))
  end)

  test('rings: a segment whose chunks are missing waits and asks for them', function()
    local rings, _, surface, force = ring_world()
    local obstacles = require('scripts.engineers.rings.obstacles')
    local scan = obstacles.scan
    obstacles.scan = function() return nil end
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    game.tick = 10
    local result = rings.plan_segment(ring, 2)
    obstacles.scan = scan
    assert(result == 'generating' and ring.segments[2].due == 10 + rings.RETRY)
  end)

  test('rings: ring claims take only ring ghosts, other claims never do', function()
    local rings, s, surface, force = ring_world()
    local ghosts = require('scripts.engineers.ghosts')
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    ring.segments[2].state = 'placed'
    rings.place(ring, 2, {{x = 200.5, y = 0.5, name = 'stone-wall', dir = 'east', a = 0}}, surface, force)
    local own = surface.create_entity{name = 'entity-ghost', inner_name = 'stone-wall', position = {x = 190.5, y = 0.5}}
    ghosts.add(own)
    -- Robots reach everything: step 1 claims skip covered ghosts, ring claims do not.
    surface.find_logistic_networks_by_construction_area = function() return {{}} end
    local c = ctx.soldier(nil, nil, 180, 0)
    local record = {id = c.unit_number, entity = c, surface_index = 1, force_index = 1}
    assert(ghosts.claim(record, 3, 9) == nil, 'a manual claim took a covered or ring ghost')
    local cluster = ghosts.claim(record, 3, 9, {ring = true})
    assert(cluster and #cluster == 1 and s.ring_ghosts[cluster[1].id], 'no ring ghost claimed')
    ghosts.release(cluster)
    assert(ghosts.claim(record, 3, 9, {ring = ring.key, segment = 1}) == nil, 'another segment was claimed')
    assert(ghosts.claim(record, 3, 9, {ring = ring.key, segment = 2}), 'own segment not claimed')
    assert(ghosts.count(1, 1) == 0, 'the window counts ring ghosts or covered ghosts')
  end)

  -- An autonomous constructor at (x, y) with no escort needed, in a ring
  -- world where segments scan as empty ground, no enemy is near and the
  -- ring interiors count as read and clear. The last value returned puts
  -- the replaced functions back; every test that uses this calls it at its
  -- end.
  local function autonomous_at(x, y)
    local rings, s = ring_world()
    s.min_team = 0
    local obstacles = require('scripts.engineers.rings.obstacles')
    local layout = require('scripts.engineers.rings.layout')
    local clearing = require('scripts.engineers.rings.clearing')
    local constructor = require('scripts.engineers.constructor')
    local saved = {scan = obstacles.scan, enemy_near = constructor.enemy_near, plan = layout.plan,
      holds = clearing.holds}
    obstacles.scan = function() return {bulges = {}, crossings = {}, water = {}} end
    constructor.enemy_near = function() return false end
    clearing.holds = function() return false end
    local function restore()
      obstacles.scan, constructor.enemy_near, layout.plan = saved.scan, saved.enemy_near, saved.plan
      clearing.holds = saved.holds
    end
    local e = ctx.soldier(nil, nil, x, y)
    e.name, e.health, e.max_health = names.constructor, 800, 800
    local record = constructor.register(e)
    constructor.set_autonomous(record.id, true)
    return record, constructor, rings, s, restore
  end

  test('rings: an autonomous constructor plans the segment nearest it and claims its ghosts', function()
    local record, constructor, _, s, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      constructor.seek(record)
      assert(record.state == 'moving', 'state ' .. record.state)
      assert(record.segment and record.segment.index == 2, 'planned the wrong segment')
      assert(#record.cluster > 0 and #record.cluster <= 9, #record.cluster .. ' ghosts claimed')
      for _, entry in ipairs(record.cluster) do assert(s.ring_ghosts[entry.id].segment == 2) end
    end)
    restore()
    assert(ok, err)
  end)

  test('rings: a second constructor leaves the first one\'s segment alone and plans its own', function()
    local record, constructor, _, s, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      constructor.seek(record)
      assert(record.segment.index == 2)
      local e = ctx.soldier(nil, nil, 250, 10)
      e.name, e.health, e.max_health = names.constructor, 800, 800
      local other = constructor.register(e)
      constructor.set_autonomous(other.id, true)
      game.tick = game.tick + 1
      constructor.seek(other)
      assert(other.segment and other.segment.index ~= 2, 'the second constructor joined segment 2')
      for _, entry in ipairs(other.cluster) do
        assert(s.ring_ghosts[entry.id].segment == other.segment.index, 'claimed a ghost of another segment')
      end
    end)
    restore()
    assert(ok, err)
  end)

  test('rings: ghosts nobody works on come before a farther new segment', function()
    local record, constructor, _, s, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      constructor.seek(record)
      -- The first constructor goes away and lets its segment go.
      constructor.unregister(record.id)
      local e = ctx.soldier(nil, nil, 250, 10)
      e.name, e.health, e.max_health = names.constructor, 800, 800
      local other = constructor.register(e)
      constructor.set_autonomous(other.id, true)
      game.tick = game.tick + 1
      constructor.seek(other)
      assert(other.cluster and s.ring_ghosts[other.cluster[1].id].segment == 2, 'the left segment was not taken up')
      assert(not other.segment, 'planned a new segment with work at hand')
    end)
    restore()
    assert(ok, err)
  end)

  test('rings: a constructor sweeps its segment from where it stands, all rows at once', function()
    local record, constructor, rings, s, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      constructor.seek(record)
      constructor.reset(record)
      record.segment = {ring = rings.key(1, 1), index = 2}
      record.entity.position = {x = 195.5, y = -40.5}
      local ring = rings.by_key(rings.key(1, 1))
      while ring.placing and ring.placing[2] do rings.place_pending(ring, 2, rings.PLACE_BATCH) end
      local cluster = rings.claim(record, 3, 9)
      local geometry = require('scripts.engineers.rings.geometry')
      local rows = {}
      for _, entry in ipairs(cluster) do
        local _, a, d = geometry.to_frame(ring, entry.position.x, entry.position.y)
        assert(math.abs(a + 41) <= 3, 'claimed along ' .. a .. ', away from the constructor')
        rows[d] = true
      end
      assert(rows[-1] and rows[1], 'the cluster does not cross the band')
    end)
    restore()
    assert(ok, err)
  end)

  test('rings: a claim on its own segment does not rank every chunk of ghosts', function()
    local record, constructor, rings, s, restore = autonomous_at(250, 0)
    local ghosts = require('scripts.engineers.ghosts')
    local chunk_distance2, calls = ghosts.chunk_distance2, 0
    local ok, err = pcall(function()
      constructor.seek(record)
      constructor.reset(record)
      record.segment = {ring = rings.key(1, 1), index = 2}
      local ring = rings.by_key(rings.key(1, 1))
      while ring.placing and ring.placing[2] do rings.place_pending(ring, 2, rings.PLACE_BATCH) end
      -- Player ghosts in 2000 chunks far away.
      local surface = game.surfaces[1]
      for i = 1, 2000 do
        ghosts.add(surface.create_entity{name = 'entity-ghost', inner_name = 'stone-wall',
          position = {x = 5000 + (i % 50) * 32, y = 5000 + math.floor(i / 50) * 32}})
      end
      ghosts.chunk_distance2 = function(...) calls = calls + 1; return chunk_distance2(...) end
      local cluster = rings.claim(record, 3, 9)
      assert(cluster and s.ring_ghosts[cluster[1].id].segment == 2, 'own segment not claimed')
    end)
    ghosts.chunk_distance2 = chunk_distance2
    restore()
    assert(ok, err)
    assert(calls <= 50, calls .. ' chunk distances for a claim on one segment')
  end)

  test('rings: a segment\'s ghosts go up along the ring from the end nearest its constructor', function()
    local rings = require('scripts.engineers.rings.rings')
    local layout = require('scripts.engineers.rings.layout')
    for _, ring in ipairs({square(200), circle(300)}) do
      local seg = geometry.segment(ring, 2)
      local near_hi = geometry.to_position(ring, seg.side, seg.hi + 20, -10)
      local tiles = rings.sweep_order(ring, 2, layout.plan(ring, 2, {}), near_hi)
      for k = 2, #tiles do assert(tiles[k].a <= tiles[k - 1].a, ring.shape .. ': out of order at ' .. k) end
      local near_lo = geometry.to_position(ring, seg.side, seg.lo - 20, -10)
      tiles = rings.sweep_order(ring, 2, tiles, near_lo)
      for k = 2, #tiles do assert(tiles[k].a >= tiles[k - 1].a, ring.shape .. ': out of order at ' .. k) end
    end
  end)

  test('rings: the sweep ranks rows across the band below tiles along it', function()
    local geometry = require('scripts.engineers.rings.geometry')
    for _, ring in ipairs({square(200), circle(300)}) do
      local from = geometry.stand(ring, 200.5, -40.5, 'inside')
      local score = geometry.sweep_score(ring, from)
      local _, a = geometry.to_frame(ring, from.x, from.y)
      local deep = geometry.to_position(ring, ring.shape == 'circle' and 0 or 1, a, 4)
      local beside = geometry.to_position(ring, ring.shape == 'circle' and 0 or 1, a + 3, -1)
      assert(score(deep) < score(beside), ring.shape .. ': the far row ranks below the next tile along')
      for _, p in ipairs({deep, beside, {x = 0, y = 0}, {x = -200, y = 40}}) do
        local dx, dy = p.x - from.x, p.y - from.y
        assert(score(p) >= dx * dx + dy * dy - 1e-9, 'the score is below the squared distance')
      end
    end
  end)

  test('rings: one segment is planned per tick however many constructors ask', function()
    local record, constructor, _, _, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      -- Segments with nothing to place: no ghost is left for the second
      -- constructor to help with.
      require('scripts.engineers.rings.layout').plan = function() return {} end
      constructor.seek(record)
      local e = ctx.soldier(nil, nil, -250, 0)
      e.name, e.health, e.max_health = names.constructor, 800, 800
      local other = constructor.register(e)
      constructor.set_autonomous(other.id, true)
      constructor.seek(other)
      assert(other.state == 'seeking' and not other.segment, 'a second segment was planned in the same tick')
      game.tick = game.tick + 1
      constructor.seek(other)
      assert(other.segment and other.segment.index == 8, 'the second constructor did not take the west side')
    end)
    restore()
    assert(ok, err)
  end)

  test('rings: with every ring done an autonomous constructor parks, and a change wakes it', function()
    local record, constructor, rings, _, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      rings.set(1, 'count', 1)
      local ring = rings.start(rings.force_state(1), game.forces[1], 1, game.surfaces[1])
      for _, seg in ipairs(ring.segments) do seg.state = 'built' end
      ring.state = 'built'
      constructor.seek(record)
      assert(record.state == 'idle', 'state ' .. record.state)
      assert(record.rings_version == rings.version(1))
      game.tick = game.tick + 60
      constructor.check(record, {retreat = 0})
      assert(record.state == 'idle', 'woke without a change')
      rings.set(1, 'count', 2)
      constructor.check(record, {retreat = 0})
      assert(record.state == 'moving' and record.segment and record.segment.ring == rings.key(1, 2),
        'did not start ring 2')
    end)
    restore()
    assert(ok, err)
  end)

  test('rings: switching a constructor to manual lets go of its ring claims', function()
    local record, constructor, _, s, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      constructor.seek(record)
      local claimed = record.cluster[1].id
      constructor.set_autonomous(record.id, false)
      assert(not record.autonomous and not record.segment and not s.claims[claimed])
      assert(record.state == 'seeking')
    end)
    restore()
    assert(ok, err)
  end)

  -- Ring 1 of radius 200 with segment 2 (east, gatehouse at along 0)
  -- placed, and one ring ghost built into a wall at (200.5, 50.5).
  local function breach_world()
    local rings, s, surface, force = ring_world()
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    for _, seg in ipairs(ring.segments) do seg.state = 'built' end
    ring.state = 'built'
    return rings, s, surface, force, ring
  end

  test('rings: a ring wall that dies gets its ghost back and its segment is built again', function()
    local rings, s, surface, force, ring = breach_world()
    local breached, saved = {}, rings.on_breach
    rings.on_breach = function(r, i) breached[#breached + 1] = i end
    local version = rings.version(1)
    local killer = {index = 2, name = 'enemy'}
    rings.on_wall_died{force = killer, surface_index = 1, position = {x = 200.5, y = 50.5},
      prototype = {name = 'stone-wall'}}
    rings.on_breach = saved
    local seg = ring.segments[2]
    assert(seg.state == 'placed' and seg.live == 1, 'segment ' .. seg.state .. ', ' .. seg.live .. ' live')
    assert(ring.state == 'building' and breached[1] == 2 and rings.version(1) > version)
    local id = next(seg.ghosts)
    assert(s.ring_ghosts[id].segment == 2)
  end)

  test('rings: a ghost the force left for a dead wall is tagged, not doubled', function()
    local rings, s, surface, force, ring = breach_world()
    local left = surface.create_entity{name = 'entity-ghost', inner_name = 'gate', position = {x = 200.5, y = 0.5}}
    rings.on_wall_died{surface_index = 1, position = {x = 200.5, y = 0.5}, prototype = {name = 'gate'}, ghost = left}
    assert(s.ring_ghosts[left.unit_number] and ring.segments[2].live == 1)
  end)

  test('rings: a released tile, a wall outside the rings or another wall type is not rebuilt', function()
    local rings, _, _, _, ring = breach_world()
    ring.released['200,50'] = true
    rings.on_wall_died{surface_index = 1, position = {x = 200.5, y = 50.5}, prototype = {name = 'stone-wall'}}
    rings.on_wall_died{surface_index = 1, position = {x = 150.5, y = 50.5}, prototype = {name = 'stone-wall'}}
    rings.on_wall_died{surface_index = 1, position = {x = 200.5, y = 60.5}, prototype = {name = 'modded-wall'}}
    assert(ring.segments[2].live == 0 and ring.state == 'built')
  end)

  test('rings: a mined ring wall is released, except during tear-down', function()
    local rings, _, _, _, ring = breach_world()
    local wall = ctx.soldier(nil, nil, 200.5, 50.5)
    wall.type = 'wall'
    rings.on_wall_mined(wall)
    assert(ring.released['200,50'], 'a mined wall was not released')
    ring.state = 'tearing_down'
    local other = ctx.soldier(nil, nil, 200.5, 51.5)
    other.type = 'wall'
    rings.on_wall_mined(other)
    assert(not ring.released['200,51'], 'a wall taken down with its ring was released')
  end)

  test('rings: mined walls and gates reach the rings through filtered events', function()
    dofile('control.lua')
    for _, event in ipairs({'on_player_mined_entity', 'on_robot_mined_entity'}) do
      local filters = assert(ctx.filters()[event], event .. ' is unfiltered')
      local types = {}
      for _, f in ipairs(filters) do types[f.type] = f.filter == 'type' end
      assert(types.wall and types.gate and #filters == 2, event .. ' has the wrong filters')
    end
  end)

  -- A wall of the ring's force at a world position, with the calls the
  -- tear-down makes.
  local function ring_wall(x, y, name)
    local w = ctx.soldier(nil, nil, x, y)
    w.name, w.type = name or 'stone-wall', name == 'gate' and 'gate' or 'wall'
    w.force_index, w.surface_index = 1, 1
    w.order_deconstruction = function() w.marked = true end
    w.destroy = function() w.valid = false end
    return w
  end

  test('rings: deleting a ring removes its ghosts at once and starts the tear-down', function()
    local rings, s, surface, force = ring_world()
    local fs = rings.force_state(1)
    local ring = rings.start(fs, force, 1, surface)
    ring.segments[2].state = 'placed'
    rings.place(ring, 2, {{x = 200.5, y = 0.5, name = 'stone-wall', dir = 'east', a = 0}}, surface, force)
    local id = next(ring.segments[2].ghosts)
    local ghost = ring.segments[2].ghosts[id].entity
    local told, saved = nil, rings.on_teardown
    rings.on_teardown = function(r) told = r end
    assert(rings.delete(1, 1))
    rings.on_teardown = saved
    assert(ring.state == 'tearing_down' and ring.teardown == 1 and told == ring)
    assert(not ghost.valid and not s.ring_ghosts[id] and ring.segments[2].live == 0)
    assert(not rings.delete(1, 1), 'a ring was deleted twice')
  end)

  test('rings: the tear-down marks walls segment by segment, then the ring is deleted', function()
    local rings, _, surface, force = ring_world()
    local dismantle = require('scripts.engineers.rings.dismantle')
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    local walls = {ring_wall(200.5, 0.5), ring_wall(200.5, 1.5, 'gate'), ring_wall(150.5, 0.5)}
    rings.delete(1, 1)
    for _ = 1, ring.count do rings.sweep_teardown(ring, game.tick) end
    assert(walls[1].marked and walls[2].marked and not walls[3].marked, 'wrong walls marked')
    assert(dismantle.count(ring.key) == 2)
    rings.sweep_teardown(ring, game.tick)
    assert(ring.state == 'tearing_down', 'deleted with walls standing')
    walls[1].valid, walls[2].valid = false, false
    game.tick = game.tick + rings.PURGE
    rings.sweep_teardown(ring, game.tick)
    assert(ring.state == 'deleted' and #ring.labels == 0, 'not deleted after the last wall went')
    assert(force.printed[#force.printed][1] == 'tank-squads.ring-removed')
    assert(rings.again(1, 1) and rings.force_state(1).slots[1] == nil, 'build again kept the slot')
  end)

  test('rings: autonomous constructors take walls down before building', function()
    local record, constructor, rings, _, restore = autonomous_at(250, 0)
    local ok, err = pcall(function()
      local ring = rings.start(rings.force_state(1), game.forces[1], 1, game.surfaces[1])
      local wall = ring_wall(200.5, 0.5)
      rings.delete(1, 1)
      for _ = 1, ring.count do rings.sweep_teardown(ring, game.tick) end
      constructor.seek(record)
      assert(record.dismantle and record.state == 'moving' and record.cluster[1].entity == wall)
      local crane = require('scripts.engineers.crane')
      assert(crane.place(record) == 1 and not wall.valid, 'the crane did not take the wall down')
    end)
    restore()
    assert(ok, err)
  end)

  test('rings: an open crossing that has gone is walled up', function()
    local rings, _, surface, force = ring_world()
    local obstacles = require('scripts.engineers.rings.obstacles')
    local saved = {scan = obstacles.scan, present = obstacles.crossing_present}
    obstacles.scan = function() return {bulges = {}, crossings = {}, water = {}} end
    obstacles.crossing_present = function() return false end
    local ok, err = pcall(function()
      local ring = rings.start(rings.force_state(1), force, 1, surface)
      for _, seg in ipairs(ring.segments) do seg.state = 'built' end
      ring.state = 'built'
      local tag = {valid = true}
      tag.destroy = function() tag.valid = false end
      ring.crossings['2:1:30'] = {side = 1, a0 = 30, a1 = 30, segment = 2, tag = tag, due = 0}
      rings.recheck_crossings(ring, 10)
      assert(not ring.crossings['2:1:30'] and not tag.valid, 'the crossing was kept')
      local seg = ring.segments[2]
      assert(seg.state == 'placed' and seg.live == 4, seg.state .. ' ' .. seg.live)
      assert(ring.state == 'building')
    end)
    obstacles.scan, obstacles.crossing_present = saved.scan, saved.present
    assert(ok, err)
  end)

  -- Ring 1 of radius 200 round (0, 0) with a working gatehouse in segment 2
  -- (east side, gates at x = 199 .. 201, y = -8 .. 7) and a soldier inside.
  local function crossing_world()
    local rings, s, surface, force = ring_world()
    require('scripts.engineers.init')
    defines.command.attack, defines.command.stop = 3, 4
    defines.distraction.none = 0
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    ring.state = 'built'
    local opened = {}
    local gate = {valid = true, request_to_open = function(f, ticks) opened[#opened + 1] = ticks end}
    ring.gatehouses[2] = {gates = {gate}, complete = true, inside = {x = 191.5, y = 0.5}, outside = {x = 210.5, y = 0.5}}
    local unit = ctx.soldier(nil, nil, 100, 0)
    return unit, ring, opened, s
  end

  local function go(x, y)
    return {type = defines.command.go_to_location, destination = {x = x, y = y}, radius = 4,
      distraction = defines.distraction.by_enemy}
  end

  test('rings: a unit ordered across a ring passes through a gatehouse its gates open for', function()
    local combat = require('scripts.combat')
    local crossing = require('scripts.engineers.rings.crossing')
    local unit, _, opened, s = crossing_world()
    combat.set_command(unit, go(300, 0))
    assert(unit.command.destination.x == 191.5, 'not sent to the inside apron')
    crossing.on_command_completed(unit.unit_number, defines.behavior_result.success)
    assert(opened[1] == crossing.OPEN_TICKS and unit.command.type == defines.command.stop, 'gates not opened')
    crossing.on_command_completed(unit.unit_number, defines.behavior_result.success)
    assert(unit.command.destination.x == 210.5 and #opened == 2, 'not sent through')
    unit.position = {x = 210.5, y = 0.5}
    crossing.on_command_completed(unit.unit_number, defines.behavior_result.success)
    assert(unit.command.destination.x == 300, 'the order was not taken up again')
    assert(not s.crossings[unit.unit_number])
  end)

  test('rings: no complete gatehouse: the order goes out unchanged', function()
    local combat = require('scripts.combat')
    local unit, ring = crossing_world()
    ring.gatehouses[2].complete = false
    combat.set_command(unit, go(300, 0))
    assert(unit.command.destination.x == 300)
  end)

  test('rings: an order to the wall itself or on the same side needs no crossing', function()
    local combat = require('scripts.combat')
    local unit = crossing_world()
    combat.set_command(unit, go(200.5, 5.5))
    assert(unit.command.destination.x == 200.5, 'an order onto the band went through a gatehouse')
    combat.set_command(unit, go(-100, 50))
    assert(unit.command.destination.x == -100)
  end)

  test('rings: a failed approach gives the order back without crossing', function()
    local combat = require('scripts.combat')
    local crossing = require('scripts.engineers.rings.crossing')
    local unit, _, _, s = crossing_world()
    combat.set_command(unit, go(300, 0))
    crossing.on_command_completed(unit.unit_number, defines.behavior_result.fail)
    assert(unit.command.destination.x == 300 and not s.crossings[unit.unit_number])
  end)

  test('rings: a new order while passing through keeps the crossing going', function()
    local combat = require('scripts.combat')
    local crossing = require('scripts.engineers.rings.crossing')
    local unit = crossing_world()
    combat.set_command(unit, go(300, 0))
    crossing.on_command_completed(unit.unit_number, defines.behavior_result.success)
    combat.set_command(unit, go(320, 10))
    assert(unit.command.type == defines.command.stop, 'the wait at the gate was cut short')
    crossing.on_command_completed(unit.unit_number, defines.behavior_result.success)
    unit.position = {x = 210.5, y = 0.5}
    crossing.on_command_completed(unit.unit_number, defines.behavior_result.success)
    assert(unit.command.destination.x == 320, 'the newer order was lost')
  end)

  test('rings: a built segment records its gatehouse, a breach marks it broken', function()
    local rings, _, surface, force = ring_world()
    local crossing = require('scripts.engineers.rings.crossing')
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    for y = -8, 7 do
      local g = ctx.soldier(nil, nil, 200.5, y + 0.5)
      g.name, g.type = 'gate', 'gate'
    end
    rings.segment_built(ring, 2)
    local house = ring.gatehouses[2]
    assert(house and house.complete and #house.gates == 16, 'gatehouse not recorded')
    assert(house.inside.x == 191.5 and house.outside.x == 210.5)
    crossing.breached(ring, 2)
    assert(not house.complete)
  end)

  test('rings: shredders and constructors ask for crossings too', function()
    local combat = require('scripts.combat')
    local unit = crossing_world()
    combat.direct(unit, go(300, 0))
    assert(unit.command.destination.x == 191.5, 'a direct command skipped the crossing')
  end)

  local garrison = require('scripts.engineers.rings.garrison')

  test('garrison: a quarter go as pickets, the rest by weight', function()
    local c = garrison.allocate({0, 0, 10, 0}, 8)
    assert(c[1] == 0 and c[2] == 1 and c[3] == 6 and c[4] == 1, table.concat(c, ','))
    c = garrison.allocate({1, 1, 1}, 4)
    assert(c[1] == 1 and c[2] == 2 and c[3] == 1, table.concat(c, ','))
    c = garrison.allocate({0, 0, 0, 0}, 6)
    for j = 1, 4 do assert(c[j] >= 1 and c[j] <= 2, 'uneven spread ' .. table.concat(c, ',')) end
    c = garrison.allocate({5, 5}, 0)
    assert(c[1] == 0 and c[2] == 0)
  end)

  test('garrison: posts stand 9 tiles inside the wall of their sector', function()
    local ring = square(200)
    ring.count = geometry.segment_count(ring)
    local counts = {}
    for j = 1, ring.count do counts[j] = 0 end
    counts[2] = 2
    local points = garrison.points(ring, counts)
    assert(#points == 2)
    for _, p in ipairs(points) do
      local side, along, depth = geometry.to_frame(ring, p.x, p.y)
      assert(side == 1 and depth == -9 and geometry.segment_of(ring, side, along) == 2)
    end
  end)

  test('garrison: blocks are contiguous, in the order divisions stand round the ring', function()
    local points = {{x = 1}, {x = 2}, {x = 3}, {x = 4}, {x = 5}}
    local out = garrison.blocks(points, {{key = 'b', count = 2, mean = 5}, {key = 'a', count = 3, mean = 1}})
    assert(out.a[1].x == 1 and out.a[3].x == 3 and out.b[1].x == 4 and out.b[2].x == 5)
  end)

  -- A ring of radius 200 round (0, 0) and division n of player 1 with
  -- `count` soldiers near (x, y).
  local function garrison_world()
    local rings, _, surface, force = ring_world()
    require('scripts.engineers.init')
    defines.command.attack, defines.command.stop = 3, 4
    defines.distraction.none = 0
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    local function division(n, count, x, y)
      local list = {}
      for i = 1, count do list[i] = ctx.soldier(nil, nil, x + i, y) end
      require('scripts.divisions').assign(1, n, list)
      return list
    end
    return ring, division, rings
  end

  local function posts_of(n)
    local r = require('scripts.divisions').record(1, n).patrol
    local out = {}
    for _, post in pairs(r and r.posts or {}) do out[#out + 1] = post.points[1] end
    return out
  end

  test('garrison: a division on a ring gets one hold point per soldier inside the wall', function()
    local ring, division = garrison_world()
    division(1, 4, 150, -150)
    assert(garrison.set(1, 1, 1), 'the garrison was refused')
    local record = require('scripts.divisions').record(1, 1)
    assert(record.mode == 'patrol' and record.patrol.garrison == ring.key)
    local posts = posts_of(1)
    assert(#posts == 4, #posts .. ' posts')
    for _, p in ipairs(posts) do
      local _, _, depth = geometry.to_frame(ring, p.x, p.y)
      assert(depth == -9, 'post at depth ' .. depth)
    end
    assert(garrison.active())
  end)

  test('garrison: weights pull soldiers toward the sector with nests', function()
    local ring, division = garrison_world()
    division(1, 4, 150, -150)
    garrison.set(1, 1, 1)
    local g = garrison.state(ring)
    g.weights = {[5] = 10}
    garrison.mark_all(ring, g)
    require('scripts.patrol').tick()
    local in_five = 0
    for _, p in ipairs(posts_of(1)) do
      local side, along = geometry.to_frame(ring, p.x, p.y)
      if geometry.segment_of(ring, side, along) == 5 then in_five = in_five + 1 end
    end
    assert(in_five == 3, in_five .. ' posts in the weighted sector')
  end)

  test('garrison: a division that leaves hands its posts to the others', function()
    local ring, division = garrison_world()
    division(1, 4, 150, -150)
    division(2, 4, -150, 150)
    garrison.set(1, 1, 1)
    garrison.set(1, 2, 1)
    require('scripts.patrol').tick()
    assert(garrison.set(1, 2, nil))
    assert(require('scripts.divisions').record(1, 2).mode == 'idle')
    require('scripts.patrol').tick()
    local far = 0
    for _, p in ipairs(posts_of(1)) do
      local side, along = geometry.to_frame(ring, p.x, p.y)
      if geometry.segment_of(ring, side, along) >= 7 then far = far + 1 end
    end
    assert(#posts_of(1) == 4 and far >= 1, 'division 1 did not spread round the ring alone')
  end)

  test('garrison: an empty division or a ring not standing is refused', function()
    local ring, division = garrison_world()
    assert(not garrison.set(1, 3, 1), 'an empty division joined')
    division(1, 2, 150, -150)
    ring.state = 'tearing_down'
    assert(not garrison.set(1, 1, 1), 'a ring being torn down took a garrison')
    assert(not garrison.set(1, 1, 5), 'a ring that does not exist took a garrison')
  end)

  test('garrison: tearing a ring down sends its garrison to idle', function()
    local ring, division, rings = garrison_world()
    division(1, 2, 150, -150)
    garrison.set(1, 1, 1)
    rings.delete(1, 1)
    local record = require('scripts.divisions').record(1, 1)
    assert(record.mode == 'idle' and not record.patrol and not ring.garrison)
    assert(not garrison.active())
  end)

  test('garrison: a merged force lets its rings go and its garrison stops', function()
    local ring, division, rings = garrison_world()
    division(1, 2, 150, -150)
    garrison.set(1, 1, 1)
    local dest = {index = 2, name = 'dest', is_enemy = function() return false end}
    game.forces = {[2] = dest}
    require('scripts.engineers.init').on_forces_merged{source_index = 1, source_name = 'gone', destination = dest}
    garrison.tick()
    local record = require('scripts.divisions').record(1, 1)
    assert(record.mode == 'idle' and not record.patrol, 'the garrison still holds a ring of a merged force')
    assert(rings.peek(1) == nil and not ring.garrison and not garrison.active())
  end)

  test('garrison: weights are read one sector per call and trigger a new deal', function()
    local ring, division = garrison_world()
    division(1, 4, 150, -150)
    garrison.set(1, 1, 1)
    local surface, own, enemy = game.surfaces[1], game.forces[1], {index = 2, name = 'enemy'}
    own.is_enemy = function(other) return other == enemy end
    game.forces[2] = enemy
    surface.count_entities_filtered = function(q) return (q.type == 'unit-spawner' and q.position.x > 150) and 1 or 0 end
    local g = garrison.state(ring)
    for _ = 1, ring.count do garrison.weigh(ring, g, game.tick) end
    assert(g.weights[2] == 5 and g.weights[8] == 0, 'weights ' .. tostring(g.weights[2]))
    assert(g.due == game.tick + garrison.PERIOD)
    assert(require('scripts.divisions').record(1, 1).patrol.dirty, 'the new weights were not dealt')
  end)

  -- Five garrison soldiers of division 1 just inside the east wall of a
  -- radius-200 ring, and a wall of that ring.
  local function alarm_world()
    local ring, division = garrison_world()
    local soldiers = division(1, 5, 185, 0)
    garrison.set(1, 1, 1)
    local own = game.forces[1]
    own.is_enemy = function(other) return other == 'enemy' end
    game.surfaces[1].find_units = function() return {} end
    local wall = ctx.soldier(nil, nil, 200.5, 0.5)
    wall.name, wall.type, wall.force_index, wall.surface_index = 'stone-wall', 'wall', 1, 1
    return ring, soldiers, wall
  end

  local function attacked(list)
    local n = 0
    for _, s in ipairs(list) do
      if s.command and s.command.type == defines.command.attack_area then n = n + 1 end
    end
    return n
  end

  test('garrison: a wall hit by the enemy calls the nearest garrison soldiers, once per 5 seconds', function()
    local _, soldiers, wall = alarm_world()
    local biter = ctx.soldier('enemy', nil, 210, 0)
    assert(garrison.on_wall_damaged{entity = wall, cause = biter}, 'a wall hit was passed on')
    assert(attacked(soldiers) == garrison.MIN_RESPONDERS, attacked(soldiers) .. ' responders')
    local r = require('scripts.divisions').record(1, 1).patrol
    local marked = 0
    for _ in pairs(r.responders) do marked = marked + 1 end
    assert(marked == garrison.MIN_RESPONDERS, 'responders not marked for their posts')
    for _, s in ipairs(soldiers) do s.command = nil end
    garrison.on_wall_damaged{entity = wall, cause = biter}
    assert(attacked(soldiers) == 0, 'a second alarm within 5 seconds')
  end)

  test('garrison: hits from a friend, or on a wall of no garrisoned ring, call nobody', function()
    local _, soldiers, wall = alarm_world()
    for _, s in ipairs(soldiers) do s.command = nil end
    local friend = ctx.soldier(nil, nil, 210, 0)
    assert(garrison.on_wall_damaged{entity = wall, cause = friend})
    local stray = ctx.soldier(nil, nil, 150.5, 0.5)
    stray.name, stray.type = 'stone-wall', 'wall'
    garrison.on_wall_damaged{entity = stray, cause = ctx.soldier('enemy', nil, 140, 0)}
    assert(attacked(soldiers) == 0)
    assert(not garrison.on_wall_damaged{entity = soldiers[1], cause = friend}, 'a soldier hit was taken as a wall hit')
  end)

  test('garrison: walls reach the damage handler only while a ring has a garrison', function()
    local _, division = garrison_world()
    dofile('control.lua')
    local function wall_filtered()
      for _, f in ipairs(ctx.filters().on_entity_damaged) do
        if f.filter == 'type' and f.type == 'wall' then return true end
      end
      return false
    end
    assert(not wall_filtered(), 'walls filtered in without a garrison')
    division(1, 2, 150, -150)
    garrison.set(1, 1, 1)
    assert(wall_filtered(), 'a garrison did not bring the walls in')
    garrison.set(1, 1, nil)
    assert(not wall_filtered(), 'walls stayed in after the garrison left')
    ctx.handlers().load()
    assert(not wall_filtered())
  end)

  local function open_window()
    local engineers = require('scripts.engineers.init')
    ctx.players()[1].surface_index = 1
    engineers.toggle_window(1)
    return ctx.players()[1].gui.screen.tank_squads_engineers.body, engineers
  end

  test('rings: the window sets spacing, count and shape for the force', function()
    local rings = ring_world()
    local body, engineers = open_window()
    assert(body.ring_settings.ring_spacing.text == '200' and body.ring_settings.ring_count.text == '3')
    local field = body.ring_settings.ring_spacing
    field.text = '5000'
    assert(engineers.confirmed{player_index = 1, element = field})
    assert(rings.force_state(1).settings.spacing == 1000 and field.text == '1000', 'spacing not clamped')
    local shape = body.ring_settings.ring_shape
    shape.selected_index = 2
    assert(engineers.selected{player_index = 1, element = shape})
    assert(rings.force_state(1).settings.shape == 'circle')
    assert(body.ring_list.ring_3 and not body.ring_list.ring_4, 'one row per ring up to the count')
  end)

  test('rings: deleting a ring from the window takes two clicks', function()
    local rings, _, surface, force = ring_world()
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    local body, engineers = open_window()
    assert(engineers.click{player_index = 1, element = body.ring_list.ring_delete_1})
    assert(ring.state == 'building', 'one click deleted the ring')
    body = ctx.players()[1].gui.screen.tank_squads_engineers.body
    assert(engineers.click{player_index = 1, element = body.ring_list.ring_delete_1})
    assert(ring.state == 'tearing_down', 'the second click did not delete it')
  end)

  test('rings: the auto box switches a constructor to rings', function()
    ring_world()
    local e = ctx.soldier(nil, nil, 10, 10)
    e.name, e.health, e.max_health = names.constructor, 800, 800
    local record = require('scripts.engineers.constructor').register(e)
    local body, engineers = open_window()
    local box = body.list['auto_' .. record.id]
    assert(box and box.state == false, 'no auto box')
    box.state = true
    assert(engineers.checked{player_index = 1, element = box})
    assert(record.autonomous)
  end)

  test('rings: a garrison dropdown puts a division on a ring', function()
    local rings, _, surface, force = ring_world()
    require('scripts.engineers.init')
    defines.command.attack, defines.command.stop = 3, 4
    defines.distraction.none = 0
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    require('scripts.divisions').assign(1, 2, {ctx.soldier(nil, nil, 150, -150)})
    local body, engineers = open_window()
    local drop = body.garrison.cell_2.garrison_2
    assert(body.garrison.cell_2.visible and #drop.items == 4, 'dropdown without the rings')
    drop.selected_index = 2
    assert(engineers.selected{player_index = 1, element = drop})
    assert(require('scripts.divisions').record(1, 2).patrol.garrison == ring.key)
    require('scripts.panel').update(1)
    local row = ctx.players()[1].gui.screen.tank_squads_divisions.body.divisions.row_2.division_2
    assert(row.caption[5][1] == 'tank-squads.mode-garrison' and row.caption[5][2] == 1, 'panel does not show the garrison')
  end)

  test('rings: the centre tool picks the ring centre', function()
    local rings = ring_world()
    local engineers = require('scripts.engineers.init')
    local player = ctx.players()[1]
    player.cursor = 'tank-squad-ring-centre'
    engineers.pick_centre{player_index = 1, surface = game.surfaces[1],
      area = {left_top = {x = 10, y = 20}, right_bottom = {x = 12, y = 22}}}
    local c = rings.force_state(1).settings.centre
    assert(c.x == 11 and c.y == 21 and player.cursor == nil)
  end)

  test('rings: the panel and its engineers button show while the force has rings', function()
    local rings, _, surface, force = ring_world()
    rings.start(rings.force_state(1), force, 1, surface)
    require('scripts.panel').update(1)
    local frame = ctx.players()[1].gui.screen.tank_squads_divisions
    assert(frame and frame.visible and frame.titlebar.engineers.visible)
  end)

  test('rings: the audit reads a bounded number of ghosts per call', function()
    local rings, _, surface, force = ring_world()
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    ring.segments[1].state = 'placed'
    local tiles = {}
    for k = 1, 100 do tiles[k] = {x = 200.5, y = -190.5 + k, name = 'stone-wall', dir = 'east', a = -191 + k} end
    rings.place(ring, 1, tiles, surface, force)
    local seg = ring.segments[1]
    for _, g in pairs(seg.ghosts) do g.entity.valid = false end
    rings.audit(ring)
    assert(seg.live == 100 - rings.AUDIT_BATCH, seg.live .. ' ghosts left after one call')
    rings.audit(ring)
    assert(seg.live == 0 and seg.state == 'built', 'the audit did not finish the segment')
  end)

  -- Segment 1 of a radius-200 ring planned with `n` wall tiles on two
  -- columns just inside the east wall line.
  local function planned(n)
    local rings, s, surface, force = ring_world()
    local obstacles = require('scripts.engineers.rings.obstacles')
    local layout = require('scripts.engineers.rings.layout')
    local scan, plan = obstacles.scan, layout.plan
    obstacles.scan = function() return {bulges = {}, crossings = {}, water = {}} end
    layout.plan = function()
      local tiles = {}
      for k = 1, n do
        local col, row = (k - 1) % 2, math.floor((k - 1) / 2)
        tiles[k] = {x = 200.5 + col, y = -190.5 + row, name = 'stone-wall', dir = 'east', a = -191 + row}
      end
      return tiles
    end
    local ring = rings.start(rings.force_state(1), force, 1, surface)
    local ok, result = pcall(rings.plan_segment, ring, 1)
    obstacles.scan, layout.plan = scan, plan
    assert(ok, result)
    return rings, ring, result, s
  end

  test('rings: a planned segment places its ghosts a batch at a time', function()
    local rings, ring, result = planned(150)
    local seg = ring.segments[1]
    assert(result == 'placed' and seg.live == rings.PLACE_BATCH, seg.live .. ' ghosts placed at once')
    rings.tick(3)
    assert(seg.live == 2 * rings.PLACE_BATCH, seg.live .. ' after one slice')
    rings.tick(4)
    assert(seg.live == 150 and not seg.pending, 'the rest was not placed')
  end)

  test('rings: a segment is not built while ghosts wait to be placed', function()
    local rings, ring = planned(150)
    local seg = ring.segments[1]
    local ids = {}
    for id, g in pairs(seg.ghosts) do ids[#ids + 1] = {id, g.position} end
    for _, v in ipairs(ids) do rings.ghost_gone(v[1], v[2], true) end
    assert(seg.live == 0 and seg.state == 'placed', 'built with ghosts still to place')
    for phase = 1, 3 do rings.tick(phase) end
    ids = {}
    for id, g in pairs(seg.ghosts) do ids[#ids + 1] = {id, g.position} end
    for _, v in ipairs(ids) do rings.ghost_gone(v[1], v[2], true) end
    assert(seg.state == 'built', 'not built after the last ghost')
  end)

  test('rings: a constructor with nothing placed left places the next batch of its segment', function()
    local rings, ring, _, s = planned(150)
    local seg = ring.segments[1]
    for id in pairs(seg.ghosts) do s.claims[id] = 999 end
    local c = ctx.soldier(nil, nil, 190, -170)
    local record = {id = c.unit_number, entity = c, surface_index = 1, force_index = 1, autonomous = true,
      segment = {ring = ring.key, index = 1, near = {x = 200.5, y = -150.5}}}
    local cluster = rings.claim(record, 3, 9)
    assert(cluster and seg.live == 2 * rings.PLACE_BATCH, 'no new batch for the constructor')
  end)

  test('rings: a constructor with no segment of its own places a batch before planning a new one', function()
    local rings, ring, _, s = planned(150)
    local seg = ring.segments[1]
    for id in pairs(seg.ghosts) do s.claims[id] = 999 end
    local c = ctx.soldier(nil, nil, 190, -170)
    local record = {id = c.unit_number, entity = c, surface_index = 1, force_index = 1, autonomous = true}
    local cluster, mode = rings.claim(record, 3, 9)
    assert(cluster and mode == 'build', 'no cluster: ' .. tostring(mode))
    assert(seg.live == 2 * rings.PLACE_BATCH and ring.segments[2].state == 'unplanned', 'a new segment was planned')
  end)

  test('rings: the engine test reset removes a force rings with their map labels', function()
    local rings, _, surface, force = ring_world()
    local engineers = require('scripts.engineers.init')
    local before = #ctx.draws()
    rings.set_centre(force, surface, {x = 5, y = 5})
    rings.start(rings.force_state(1), force, 1, surface)
    engineers.ring_reset(force)
    for k = before + 1, #ctx.draws() do assert(not ctx.draws()[k].valid, 'a ring render was left on the map') end
    assert(rings.peek(1) == nil, 'the rings stayed')
  end)

  test('rings: planning reads deep rows only beside a bulge', function()
    local ring = square(200)
    local o = {bulges = {{side = 1, a0 = -180, a1 = -170, depth = 60, kind = 'bulge'}}}
    local cell, calls = layout.cell, 0
    layout.cell = function(...) calls = calls + 1; return cell(...) end
    local ok, err = pcall(layout.plan, ring, 1, o)
    layout.cell = cell
    assert(ok, err)
    local seg = geometry.segment(ring, 1)
    local plain = (seg.hi - seg.lo + 1) * 8
    assert(calls < plain + 20 * 70, calls .. ' cells read for ' .. plain .. ' plain ones')
  end)
end
