return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local geometry = require('scripts.patrol_geometry')
  local divisions = require('scripts.divisions')
  local patrol = require('scripts.patrol')

  local function close(a, b) return math.abs(a - b) < 1e-6 end
  local function distance(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

  test('patrol geometry: the centre is the area centroid, or the waypoint average without area', function()
    local c = geometry.centre({{x = 0, y = 0}, {x = 100, y = 0}, {x = 100, y = 100}, {x = 0, y = 100}})
    assert(close(c.x, 50) and close(c.y, 50), 'square centre at ' .. c.x .. ',' .. c.y)
    -- Extra waypoints along one edge do not pull the centre towards it.
    c = geometry.centre({{x = 0, y = 0}, {x = 25, y = 0}, {x = 50, y = 0}, {x = 75, y = 0}, {x = 100, y = 0},
      {x = 100, y = 100}, {x = 0, y = 100}})
    assert(close(c.x, 50) and close(c.y, 50), 'bunched waypoints moved the centre')
    c = geometry.centre({{x = 1000010, y = 5}, {x = 1000030, y = 5}})
    assert(close(c.x, 1000020) and close(c.y, 5), 'two-waypoint centre')
    c = geometry.centre({{x = 0, y = 0}, {x = 10, y = 0}, {x = 20, y = 0}})
    assert(close(c.x, 10) and close(c.y, 0), 'a straight route did not fall back to the average')
    c = geometry.centre({{x = 7, y = 9}})
    assert(c.x == 7 and c.y == 9)
  end)

  test('patrol geometry: lanes split the enclosed area into equal bands', function()
    assert(geometry.lane_scale(1, 1) == 1 and geometry.lane_scale(1, 4) == 1, 'lane 1 is not the route')
    local previous = 1
    for k = 1, 4 do
      local s = geometry.lane_scale(k, 4)
      local inner = k < 4 and geometry.lane_scale(k + 1, 4) or 0
      assert(close(s * s - inner * inner, 0.25), 'band ' .. k .. ' is not a quarter of the area')
      assert(s <= previous)
      previous = s
    end
    local p = geometry.lane_point({x = 0.35, y = 0}, {x = 0.1, y = 0.3}, 1)
    assert(p.x == 0.1 and p.y == 0.3, 'lane 1 point is not the waypoint')
    p = geometry.lane_point({x = 0, y = 0}, {x = 100, y = -40}, 0.5)
    assert(close(p.x, 50) and close(p.y, -20))
  end)

  local square = {{x = 0, y = 0}, {x = 100, y = 0}, {x = 100, y = 100}, {x = 0, y = 100}}
  local function route(n, waypoints)
    for _, w in ipairs(waypoints) do patrol.add_waypoint(1, n, w, game.surfaces[1]) end
    return divisions.record(1, n).patrol
  end

  test('patrol lanes: a division spreads over the route instead of meeting at one waypoint', function()
    prototypes = nil
    local members = {}
    for i = 1, 4 do members[i] = soldier(nil, nil, -20 - i, -10) end
    divisions.assign(1, 1, members)
    local r = route(1, square)
    patrol.start(1, 1)
    local centre, seen = {x = 50, y = 50}, {}
    for k = 1, 4 do
      local e = game.get_entity_by_unit_number(r.members[k])
      local d = distance(e.command.destination, centre)
      assert(close(d, distance(square[1], centre) * geometry.lane_scale(k, 4)), 'lane ' .. k .. ' off its scale')
      assert(not seen[d], 'two soldiers share a lane')
      seen[d] = true
      assert(e.command.radius == 4 and e.command.distraction == defines.distraction.by_enemy)
    end
    local leader = game.get_entity_by_unit_number(r.leader)
    assert(leader.command.destination.x == 0 and leader.command.destination.y == 0, 'leader is not on the route')
  end)

  test('patrol lanes: soldiers keep their lane from leg to leg', function()
    prototypes = nil
    local members = {}
    for i = 1, 5 do members[i] = soldier(nil, nil, 3 * i, 7 * i) end
    divisions.assign(1, 1, members)
    local r = route(1, square)
    patrol.start(1, 1)
    local lane = {}
    for k, id in ipairs(r.members) do lane[id] = k end
    for _ = 1, 4 do
      for _, e in ipairs(members) do e.position = e.command.destination end
      patrol.advance(r.leader)
      for k, id in ipairs(r.members) do assert(lane[id] == k, 'a soldier changed lanes') end
    end
    assert(r.index == 1, 'the leader did not walk the whole route')
  end)

  test('patrol lanes: steady legs reuse the lanes and a membership change reassigns them', function()
    prototypes = nil
    local members, reads = {}, {}
    for i = 1, 4 do members[i] = soldier(nil, nil, 10 * i, 0) end
    divisions.assign(1, 1, members)
    local r = route(1, square)
    patrol.start(1, 1)
    for i = 1, 4 do reads[i] = ctx.count_reads(members[i], 'position') end
    patrol.advance(r.leader)
    for i = 1, 4 do assert(reads[i].n == 0, 'a steady leg re-read positions') end
    local gone = game.get_entity_by_unit_number(r.members[1])
    divisions.assign(1, 2, {gone})
    assert(#r.members == 3 and r.leader ~= gone.unit_number, 'the departed leader kept its lane')
    local total = 0
    for i = 1, 4 do total = total + reads[i].n end
    assert(total == 3, 'the survivors were not reassigned lanes')
    -- A route saved before lanes existed is assigned lanes once.
    r.lanes = nil
    patrol.advance(r.leader)
    assert(r.lanes, 'a legacy route was not assigned lanes')
  end)

  test('patrol lanes: the slowest soldier walks the route and leads', function()
    prototypes = {entity = {['tank-squad-soldier-1'] = {speed = 0.12}, ['tank-squad-flame'] = {speed = 0.07},
      ['tank-squad-siege'] = {speed = 0.085}}}
    local fast1, fast2 = soldier(nil, nil, -50, -50), soldier(nil, nil, -60, -60)
    local flame, siege = soldier(nil, nil, 50, 50), soldier(nil, nil, 40, 40)
    flame.name, siege.name = 'tank-squad-flame', 'tank-squad-siege'
    divisions.assign(1, 1, {fast1, flame, siege, fast2})
    local r = route(1, square)
    patrol.start(1, 1)
    prototypes = nil
    assert(r.leader == flame.unit_number, 'a faster soldier leads the legs')
    assert(flame.command.destination.x == 0 and flame.command.destination.y == 0, 'leader is not on the route')
    -- The rest take lanes by distance from the centre: the farthest the outermost.
    assert(r.members[2] == fast2.unit_number and r.members[3] == fast1.unit_number and r.members[4] == siege.unit_number)
  end)

  test('patrol lanes: a one-waypoint route keeps everyone on the waypoint', function()
    prototypes = nil
    local a, b, c = soldier(nil, nil, 5, 0), soldier(nil, nil, 9, 0), soldier(nil, nil, 1, 3)
    divisions.assign(1, 1, {a, b, c})
    route(1, {{x = 30, y = -12}})
    patrol.start(1, 1)
    for _, e in ipairs({a, b, c}) do
      assert(e.command.destination.x == 30 and e.command.destination.y == -12, 'one-waypoint route spread out')
    end
  end)

  test('patrol lanes: members on another surface take no lane', function()
    prototypes = nil
    local a, b = soldier(nil, nil, 5, 0), soldier(nil, {index = 2}, 5, 0)
    divisions.assign(1, 1, {a, b})
    local r = route(1, square)
    patrol.start(1, 1)
    assert(#r.members == 1 and r.leader == a.unit_number and b.command == nil)
    assert(a.command.destination.x == 0 and a.command.destination.y == 0, 'a lone soldier left the route')
  end)
end
