return function(ctx)
  local test = ctx.test
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

  test('rings: a gatehouse is 16 gates wide in three rows, flanked by bastions, lane clear', function()
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
    assert(gates == 48, gates .. ' gates')
    for u = -8, 7 do
      for d = 2, 4 do assert(not at(ring, map, 1, u, d), 'lane blocked at ' .. u .. ',' .. d) end
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
      for a = -198, 204 do assert(at(ring, map, side, a, -1), 'inner wall open at side ' .. side .. ' along ' .. a) end
    end
  end)

  test('rings: a circle segment keeps walls on the band and gates in straight rows', function()
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
    assert(gates == 48, gates .. ' gates')
    for y, n in pairs(rows) do assert(n == 16, 'gate row ' .. y .. ' has ' .. n) end
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
    for d = -1, 1 do assert(at(ring, map, 1, -176, d).name == 'gate', 'rail gate missing in row ' .. d) end
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
end
