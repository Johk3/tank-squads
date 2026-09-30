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
end
