return function(ctx)
  local test = ctx.test
  local geometry = require('scripts.scout_geometry')

  local function close(a, b) return math.abs(a - b) < 1e-6 end
  local function entries(kinds)
    local out = {}
    for i, kind in ipairs(kinds) do out[i] = {id = i, kind = kind} end
    return out
  end
  local function count_kind(team, list, kind)
    local by_id, n = {}, 0
    for _, e in ipairs(list) do by_id[e.id] = e.kind end
    for _, id in ipairs(team) do if by_id[id] == kind then n = n + 1 end end
    return n
  end

  test('scout geometry: team count grows to four, then teams grow instead', function()
    local cases = {{1, 1, 1}, {2, 2, 1}, {5, 5, 1}, {6, 6, 2}, {8, 8, 2}, {9, 9, 3}, {12, 12, 4}, {40, 40, 4}}
    for _, c in ipairs(cases) do
      assert(geometry.team_count(c[1], c[2]) == c[3], c[1] .. ' soldiers gave ' .. geometry.team_count(c[1], c[2]))
    end
    assert(geometry.team_count(7, 1) == 1, 'teams outnumbered the front soldiers')
    assert(geometry.team_count(6, 0) == 1, 'a siege-only division did not form one team')
  end)

  test('scout geometry: dealing balances every kind and every team size', function()
    local kinds = {}
    for _ = 1, 14 do kinds[#kinds + 1] = 'carrier' end
    for _ = 1, 6 do kinds[#kinds + 1] = 'siege' end
    for _ = 1, 4 do kinds[#kinds + 1] = 'flame' end
    local list = entries(kinds)
    local teams = geometry.deal(list, 3)
    assert(#teams == 3, 'wrong team count')
    for _, kind in ipairs({'carrier', 'siege', 'flame'}) do
      local low, high = math.huge, 0
      for _, team in ipairs(teams) do
        local n = count_kind(team, list, kind)
        low, high = math.min(low, n), math.max(high, n)
      end
      assert(high - low <= 1, kind .. ' split unevenly: ' .. low .. '..' .. high)
    end
    local low, high = math.huge, 0
    for _, team in ipairs(teams) do low, high = math.min(low, #team), math.max(high, #team) end
    assert(high - low <= 1, 'team sizes differ by more than one')
    local reversed = {}
    for i = #list, 1, -1 do reversed[#reversed + 1] = list[i] end
    local again = geometry.deal(reversed, 3)
    for t = 1, 3 do
      for i = 1, #teams[t] do assert(teams[t][i] == again[t][i], 'dealing depends on input order') end
    end
  end)

  test('scout geometry: every dealt team gets a front soldier when teams do not outnumber them', function()
    local list = entries({'siege', 'siege', 'siege', 'siege', 'siege', 'siege', 'carrier', 'carrier'})
    local teams = geometry.deal(list, geometry.team_count(8, 2))
    for i, team in ipairs(teams) do
      assert(count_kind(team, list, 'carrier') >= 1, 'team ' .. i .. ' has no front soldier')
    end
  end)

  test('scout geometry: sectors split the compass from east, and merged ranges count', function()
    local sectors = geometry.sectors(4)
    assert(#sectors == 4 and close(sectors[1][1].from, 0) and close(sectors[1][1].to, math.pi / 2))
    assert(close(sectors[4][1].to, 2 * math.pi), 'last sector does not end at a full turn')
    local origin = {x = 100, y = 100}
    assert(close(geometry.angle(origin, {x = 110, y = 100}), 0), 'east is not angle 0')
    assert(geometry.in_sectors(sectors[1], geometry.angle(origin, {x = 110, y = 100})))
    assert(geometry.in_sectors(sectors[2], geometry.angle(origin, {x = 100, y = 110})), '+y is not in sector 2')
    local just_below = geometry.angle(origin, {x = 110, y = 99.999})
    assert(just_below > 6 and geometry.in_sectors(sectors[4], just_below), 'angle below east did not wrap to sector 4')
    local merged = {{from = 0, to = 1}, {from = 3, to = 4}}
    assert(geometry.in_sectors(merged, 3.5) and not geometry.in_sectors(merged, 2), 'merged ranges ignored')
  end)

  test('scout geometry: march angles cover the widest range, middle first', function()
    local w = (math.pi / 2) / 5
    local angles = geometry.march_angles({{from = 0, to = math.pi / 2}})
    local expected = {2.5 * w, 1.5 * w, 3.5 * w, 0.5 * w, 4.5 * w}
    assert(#angles == geometry.MARCH_ANGLES)
    for i = 1, 5 do assert(close(angles[i], expected[i]), 'march angle ' .. i .. ' is ' .. angles[i]) end
    for _, a in ipairs(geometry.march_angles({{from = 0, to = 0.1}, {from = 1, to = 2}})) do
      assert(a > 1 and a < 2, 'march angle left the widest range')
    end
  end)

  test('scout geometry: a hop advances 32 tiles and stops at the target', function()
    local point, heading, reach = geometry.hop({x = 0, y = 0}, {x = 100, y = 0})
    assert(close(point.x, 32) and close(point.y, 0) and close(heading.x, 1) and not reach)
    point, heading, reach = geometry.hop({x = 0, y = 0}, {x = 20, y = 0})
    assert(point.x == 20 and point.y == 0 and reach, 'short hop not clamped to the target')
    assert(geometry.hop({x = 0, y = 0}, {x = 0.5, y = 0}) == nil, 'a hop under one tile was planned')
  end)

  local function members(kinds, positions)
    local out = {}
    for i, kind in ipairs(kinds) do
      out[i] = {id = i, kind = kind, position = positions and positions[i] or {x = 0, y = 0}}
    end
    return out
  end
  local function forward(slot, point, heading)
    return (slot.position.x - point.x) * heading.x + (slot.position.y - point.y) * heading.y
  end
  local function lateral(slot, point, heading)
    return -(slot.position.x - point.x) * heading.y + (slot.position.y - point.y) * heading.x
  end
  local function spaced(slots, minimum)
    local list = {}
    for _, s in pairs(slots) do list[#list + 1] = s.position end
    for i = 1, #list do
      for j = i + 1, #list do
        assert(geometry.distance(list[i], list[j]) >= minimum, 'two slots closer than ' .. minimum .. ' tiles')
      end
    end
  end

  test('scout geometry: spearhead puts flames in front, a carrier V behind, sieges 30 back', function()
    for _, heading in ipairs({{x = 1, y = 0}, {x = 0, y = 1}, {x = -math.sqrt(0.5), y = -math.sqrt(0.5)}}) do
      local point = {x = 100, y = 50}
      local slots = geometry.slots(members({'flame', 'carrier', 'carrier', 'carrier', 'carrier', 'siege', 'siege'}), point, heading)
      assert(slots[1].band == 'front' and close(forward(slots[1], point, heading), 0), 'flame not at the front')
      local laterals = {}
      for id = 2, 5 do
        assert(slots[id].band == 'middle', 'carrier not in the V')
        local f = forward(slots[id], point, heading)
        assert(f <= -9 + 1e-6 and f >= -12 - 1e-6, 'carrier V depth ' .. f)
        laterals[#laterals + 1] = lateral(slots[id], point, heading)
      end
      table.sort(laterals)
      assert(close(laterals[1], -9) and close(laterals[2], -6) and close(laterals[3], 6) and close(laterals[4], 9),
        'carrier V not symmetric')
      for id = 6, 7 do
        assert(slots[id].band == 'rear' and close(forward(slots[id], point, heading), -geometry.TRAIL), 'siege not trailing')
      end
      spaced(slots, 3)
    end
  end)

  test('scout geometry: each mix gets its shape', function()
    local point, heading = {x = 0, y = 0}, {x = 1, y = 0}
    local breacher = geometry.slots(members({'flame', 'carrier', 'carrier'}), point, heading)
    assert(breacher[1].band == 'front' and breacher[2].band == 'middle' and breacher[3].band == 'middle', 'breacher')
    local overwatch = geometry.slots(members({'carrier', 'carrier', 'siege'}), point, heading)
    assert(overwatch[1].band == 'front' and close(forward(overwatch[1], point, heading), 0), 'overwatch front')
    assert(overwatch[3].band == 'rear' and close(forward(overwatch[3], point, heading), -30), 'overwatch rear')
    local bulwark = geometry.slots(members({'flame', 'siege'}), point, heading)
    assert(bulwark[1].band == 'front' and bulwark[2].band == 'rear', 'bulwark')
    local line = geometry.slots(members({'carrier', 'carrier', 'carrier'}), point, heading)
    for id = 1, 3 do assert(line[id].band == 'front' and close(forward(line[id], point, heading), 0), 'line') end
    local sieges = geometry.slots(members({'siege', 'siege'}), point, heading)
    for id = 1, 2 do
      assert(sieges[id].band == 'front' and close(forward(sieges[id], point, heading), 0), 'siege-only team trails nothing')
    end
  end)

  test('scout geometry: a second front row pushes the carrier V back', function()
    local point, heading = {x = 0, y = 0}, {x = 1, y = 0}
    local kinds = {'flame', 'flame', 'flame', 'flame', 'flame', 'flame', 'flame', 'carrier', 'carrier'}
    local slots = geometry.slots(members(kinds), point, heading)
    local deepest_front = 0
    for id = 1, 7 do deepest_front = math.min(deepest_front, forward(slots[id], point, heading)) end
    assert(close(deepest_front, -geometry.SPACING), 'seven flames did not wrap into a second row')
    assert(close(forward(slots[8], point, heading), -13), 'V not pushed back by the extra row')
    spaced(slots, 3)
  end)

  test('scout geometry: soldiers take slots on their own side, so paths do not cross', function()
    local point, heading = {x = 0, y = 0}, {x = 1, y = 0}
    local slots = geometry.slots(members({'carrier', 'carrier'}, {{x = -40, y = 50}, {x = -40, y = -50}}), point, heading)
    assert(slots[1].position.y > slots[2].position.y, 'the soldier on the +y side took the -y slot')
  end)

  test('scout geometry: a team withdraws below half health or at half its formed size', function()
    assert(geometry.should_withdraw(199, 400, 4, 4), 'below half health did not withdraw')
    assert(not geometry.should_withdraw(200, 400, 4, 4), 'exactly half health withdrew')
    assert(geometry.should_withdraw(400, 400, 2, 4), 'half the team lost did not withdraw')
    assert(not geometry.should_withdraw(400, 400, 3, 4), 'one loss in four withdrew')
    assert(not geometry.should_withdraw(400, 400, 1, 1), 'a one-soldier team withdrew by count')
    assert(not geometry.should_withdraw(0, 0, 0, 1), 'an empty team withdrew')
  end)

  test('scout geometry: the peak keeps the highest ratio until the window passes', function()
    local p = geometry.peak(nil, 1, 60)
    assert(p.ratio == 1 and p.tick == 60, 'no first peak')
    assert(geometry.peak(p, 0.9, 120) == p, 'a lower ratio replaced the peak')
    assert(geometry.peak(p, 1, 120).tick == 120, 'an equal ratio did not refresh the peak')
    assert(geometry.peak(p, 0.9, 60 + geometry.DISTRESS_WINDOW) == p, 'the peak expired inside the window')
    local late = geometry.peak(p, 0.9, 61 + geometry.DISTRESS_WINDOW)
    assert(late.ratio == 0.9 and late.tick == 61 + geometry.DISTRESS_WINDOW, 'an old peak was kept')
  end)

  test('scout geometry: a drop of 15 points below the peak is distress', function()
    local p = {ratio = 1, tick = 0}
    assert(geometry.distressed(p, 0.85), 'exactly 15 points below the peak was not distress')
    assert(not geometry.distressed(p, 0.851), 'less than 15 points below the peak was distress')
    assert(geometry.distressed({ratio = 0.95, tick = 0}, 0.8), 'rounding hid a 15-point drop')
    assert(not geometry.distressed(nil, 0), 'no peak was distress')
  end)

  test('scout geometry: a slow bleed of one point per sweep never calls for help', function()
    local p, ratio = nil, 1
    for sweep = 0, 90 do
      p = geometry.peak(p, ratio, sweep * 60)
      assert(not geometry.distressed(p, ratio), 'a slow bleed called at sweep ' .. sweep)
      ratio = ratio - 0.01
    end
  end)
end
