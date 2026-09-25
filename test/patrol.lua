return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local geometry = require('scripts.patrol_geometry')
  local divisions = require('scripts.divisions')
  local patrol = require('scripts.patrol')
  local retreat = require('scripts.retreat')

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

  test('patrol geometry: rings grow with the division and each ring keeps the same spacing', function()
    assert(geometry.area({{x = 0, y = 0}, {x = 100, y = 0}, {x = 100, y = 100}, {x = 0, y = 100}}) == 10000)
    assert(geometry.area({{x = 0, y = 0}, {x = 10, y = 0}, {x = 20, y = 0}}) == 0, 'a line encloses an area')
    assert(geometry.ring_count(11, 10000, 400) == 1 and geometry.ring_count(12, 10000, 400) == 2)
    assert(geometry.ring_count(33, 10000, 400) == 2 and geometry.ring_count(34, 10000, 400) == 3)
    assert(geometry.ring_count(50, 0, 200) == 1, 'a route without area has rings')
    -- A long narrow strip keeps its rings MIN_RING_GAP apart.
    assert(geometry.ring_count(200, 1000 * 20, 2040) == 1, 'rings crowd a narrow strip')
    for _, case in ipairs({{16, 2}, {40, 3}, {5, 5}, {7, 1}}) do
      local counts, total = geometry.ring_counts(case[1], case[2]), 0
      for j, c in ipairs(counts) do
        assert(c >= 1, 'an empty ring')
        if j > 1 then assert(c <= counts[j - 1], 'an inner ring outnumbers an outer one') end
        total = total + c
      end
      assert(total == case[1] and #counts == case[2], 'ring counts lost soldiers')
    end
  end)

  test('patrol geometry: posts split the route into equal stretches with its corners', function()
    local square = {{x = 0, y = 0}, {x = 100, y = 0}, {x = 100, y = 100}, {x = 0, y = 100}}
    local posts = geometry.posts(square, true, 4)
    assert(#posts == 4)
    for k, post in ipairs(posts) do
      local length = 0
      for j = 2, #post.points do length = length + distance(post.points[j - 1], post.points[j]) end
      assert(close(length, 100), 'stretch ' .. k .. ' is ' .. length .. ' long')
    end
    -- The second stretch runs from (100, 0) to (100, 100); the third takes
    -- in no corner; a stretch from mid-edge to mid-edge takes in the corner.
    assert(#posts[2].points == 2 and close(posts[2].points[1].x, 100) and close(posts[2].points[2].y, 100))
    posts = geometry.posts(square, true, 6)
    assert(#posts[2].points == 3 and posts[2].points[2].x == 100 and posts[2].points[2].y == 0,
      'a stretch over a corner cut it')
    -- The soldier takes up its post at the middle, then walks on to the corner.
    assert(close(posts[2].anchor.x, 100) and close(posts[2].anchor.y, 0) or posts[2].next == 2)
    -- Too short to walk: the soldier holds the middle.
    posts = geometry.posts(square, true, 20)
    assert(#posts[1].points == 1 and close(posts[1].points[1].x, 10) and close(posts[1].points[1].y, 0))
    -- A lone soldier walks the whole loop.
    posts = geometry.posts(square, true, 1)
    assert(#posts[1].points == 4 and posts[1].loop)
    posts = geometry.posts({{x = 0, y = 0}, {x = 100, y = 0}}, false, 1)
    assert(#posts[1].points == 2 and not posts[1].loop, 'an open path loops')
    posts = geometry.posts({{x = 5, y = 6}}, false, 3)
    assert(#posts == 3 and posts[3].points[1].x == 5 and #posts[3].points == 1)
  end)

  test('patrol geometry: matching keeps each soldier at the post it stands on', function()
    local square = {{x = 0, y = 0}, {x = 100, y = 0}, {x = 100, y = 100}, {x = 0, y = 100}}
    local posts = geometry.posts(square, true, 8)
    local anchors, points, order = {}, {}, {3, 7, 1, 5, 8, 2, 6, 4}
    for k, post in ipairs(posts) do anchors[k] = post.anchor end
    for i, k in ipairs(order) do points[i] = {x = anchors[k].x + 1, y = anchors[k].y - 1} end
    local match = geometry.match(points, anchors, {x = 50, y = 50}, true)
    for i, k in ipairs(order) do assert(match[i] == k, 'soldier ' .. i .. ' sent across the area') end
    -- Along a line, in order along it.
    match = geometry.match({{x = 90, y = 0}, {x = 10, y = 0}}, {{x = 0, y = 0}, {x = 100, y = 0}}, {x = 50, y = 0}, false)
    assert(match[1] == 2 and match[2] == 1)
  end)

  local square = {{x = -200, y = -200}, {x = 200, y = -200}, {x = 200, y = 200}, {x = -200, y = 200}}
  local function route(n, waypoints)
    for _, w in ipairs(waypoints) do patrol.add_waypoint(1, n, w, game.surfaces[1]) end
    return divisions.record(1, n).patrol
  end
  local function targets(members)
    local out = {}
    for i, e in ipairs(members) do out[i] = e.command.destination end
    return out
  end

  test('patrol posts: a clumped division spreads round the whole perimeter', function()
    local members = {}
    for i = 1, 8 do members[i] = soldier(nil, nil, -200 + i, -200) end
    divisions.assign(1, 1, members)
    route(1, square)
    patrol.start(1, 1)
    local sides = {}
    local points = targets(members)
    for i, p in ipairs(points) do
      assert(members[i].command.radius == 4 and members[i].command.distraction == defines.distraction.by_enemy)
      assert(close(math.max(math.abs(p.x), math.abs(p.y)), 200), 'a soldier left the perimeter')
      local side = math.abs(p.x) > math.abs(p.y) and (p.x > 0 and 'e' or 'w') or (p.y > 0 and 's' or 'n')
      sides[side] = (sides[side] or 0) + 1
      for j = 1, i - 1 do assert(distance(p, points[j]) > 100, 'two soldiers crowd one stretch') end
    end
    assert(sides.n and sides.e and sides.s and sides.w, 'a side of the perimeter is left empty')
  end)

  test('patrol posts: a large division also fills the inside on inner rings', function()
    local members = {}
    for i = 1, 30 do members[i] = soldier(nil, nil, i, 0) end
    divisions.assign(1, 1, members)
    route(1, square)
    patrol.start(1, 1)
    local outer, inner = 0, 0
    for _, p in ipairs(targets(members)) do
      if close(math.max(math.abs(p.x), math.abs(p.y)), 200) then outer = outer + 1 else inner = inner + 1 end
    end
    assert(outer > inner and inner > 0, 'outer ' .. outer .. ', inner ' .. inner)
  end)

  test('patrol posts: each soldier walks its own stretch back and forth', function()
    local a, b, c = soldier(nil, nil, -190, -200), soldier(nil, nil, 190, 200), soldier(nil, nil, -190, 190)
    divisions.assign(1, 1, {a, b, c})
    local r = route(1, square)
    patrol.start(1, 1)
    local post, other = r.posts[a.unit_number], b.command
    assert(#post.points == 3 and not post.loop, 'a third of the perimeter takes in no corner')
    assert(a.command.destination == post.anchor, 'the soldier did not take up its post at the middle')
    local seen = {}
    for _ = 1, 8 do
      seen[#seen + 1] = patrol.index(1, 1, a.unit_number)
      assert(a.command.destination == patrol.target(1, 1, a.unit_number))
      a.position = a.command.destination
      patrol.advance(a.unit_number, defines.behavior_result.success)
    end
    local walked = table.concat(seen, ',')
    assert(walked == '0,2,3,2,1,2,3,2' or walked == '0,3,2,1,2,3,2,1', 'walked ' .. walked)
    assert(b.command == other, 'one soldier arriving moved another')
  end)

  test('patrol posts: a lone soldier walks the whole loop', function()
    local a = soldier(nil, nil, 0, 0)
    divisions.assign(1, 1, {a})
    local r = route(1, square)
    patrol.start(1, 1)
    assert(patrol.index(1, 1, a.unit_number) == 0)
    patrol.advance(a.unit_number, defines.behavior_result.success)
    local first = patrol.index(1, 1, a.unit_number)
    for k = 1, 4 do
      patrol.advance(a.unit_number, defines.behavior_result.success)
      assert(patrol.index(1, 1, a.unit_number) == (first + k - 1) % 4 + 1)
    end
    assert(r.posts[a.unit_number].loop)
  end)

  test('patrol posts: a steady patrol reads no other soldier on an arrival', function()
    local members, reads = {}, {}
    for i = 1, 6 do members[i] = soldier(nil, nil, 10 * i, 0) end
    divisions.assign(1, 1, members)
    route(1, square)
    patrol.start(1, 1)
    for i = 1, 6 do reads[i] = ctx.count_reads(members[i], 'position') end
    patrol.advance(members[1].unit_number, defines.behavior_result.success)
    patrol.tick()
    for i = 1, 6 do assert(reads[i].n == 0, 'an arrival read positions') end
  end)

  test('patrol posts: a headquarters holds the innermost ring', function()
    local members = {}
    for i = 1, 20 do members[i] = soldier(nil, nil, 150 + i, 150) end
    local hq = soldier(nil, nil, 199, 199)
    hq.name = 'tank-squad-headquarters'
    members[#members + 1] = hq
    divisions.assign(1, 1, members)
    route(1, square)
    patrol.start(1, 1)
    local p = hq.command.destination
    assert(math.max(math.abs(p.x), math.abs(p.y)) < 150, 'the headquarters is on the perimeter')
  end)

  test('patrol posts: recruits are dealt posts on the next sweep, without re-sending walkers', function()
    local a, b = soldier(nil, nil, -200, -200), soldier(nil, nil, 200, 200)
    divisions.assign(1, 1, {a, b})
    local r = route(1, square)
    patrol.start(1, 1)
    local walking = a.command
    local recruit = soldier(nil, nil, 0, 190)
    divisions.add_member(1, 1, recruit.unit_number, recruit)
    assert(patrol.join(divisions.record(1, 1), recruit))
    assert(recruit.command.destination.y == 200, 'the recruit did not head for the route')
    assert(r.dirty and not r.posts[recruit.unit_number])
    patrol.tick()
    assert(r.posts[recruit.unit_number] and not r.dirty, 'the recruit got no post')
    assert(a.command == walking, 'a walking soldier was re-sent')
    -- Its leg done, the walker takes up its new stretch.
    a.position = a.command.destination
    patrol.advance(a.unit_number, defines.behavior_result.success)
    assert(a.command.destination == r.posts[a.unit_number].anchor, 'the walker did not take up its new post')
  end)

  test('patrol posts: a casualty\'s stretch is shared out on the next sweep', function()
    local members = {}
    for i = 1, 3 do members[i] = soldier(nil, nil, 10 * i, 0) end
    divisions.assign(1, 1, members)
    local r = route(1, square)
    patrol.start(1, 1)
    local dead = members[3]
    divisions.forget(dead.unit_number)
    dead.valid = false
    patrol.forget(dead.unit_number)
    assert(r.dirty and not r.posts[dead.unit_number])
    patrol.tick()
    local count = 0
    for _ in pairs(r.posts) do count = count + 1 end
    assert(count == 2 and not r.dirty)
    local post, length = r.posts[members[1].unit_number], 0
    for j = 2, #post.points do length = length + distance(post.points[j - 1], post.points[j]) end
    assert(close(length, 800), 'the survivors did not take half the perimeter each')
  end)

  test('patrol posts: soldiers holding a point move only when their point does', function()
    local line = {{x = 0, y = 0}, {x = 60, y = 0}}
    local members = {}
    for i = 1, 3 do members[i] = soldier(nil, nil, 20 * i, 0) end
    divisions.assign(1, 1, members)
    local r = route(1, line)
    patrol.start(1, 1)
    for _, e in ipairs(members) do
      assert(#r.posts[e.unit_number].points == 1, 'a 20-tile stretch is walked')
      e.position = e.command.destination
      patrol.advance(e.unit_number, defines.behavior_result.success)
      assert(r.posts[e.unit_number].idle)
    end
    local sent = 0
    for _, e in ipairs(members) do e.commandable.set_command = function(c) sent = sent + 1; e.command = c end end
    patrol.tick()
    assert(sent == 0, 'a sweep re-sent soldiers holding their points')
    divisions.assign(1, 2, {members[3]})
    assert(sent == 2, 'the survivors did not move to their new points')
  end)

  test('patrol posts: a one-waypoint route keeps everyone on the waypoint', function()
    local a, b, c = soldier(nil, nil, 5, 0), soldier(nil, nil, 9, 0), soldier(nil, nil, 1, 3)
    divisions.assign(1, 1, {a, b, c})
    route(1, {{x = 30, y = -12}})
    patrol.start(1, 1)
    for _, e in ipairs({a, b, c}) do
      assert(e.command.destination.x == 30 and e.command.destination.y == -12, 'one-waypoint route spread out')
    end
  end)

  test('patrol posts: members on another surface take no post', function()
    local a, b = soldier(nil, nil, 5, 0), soldier(nil, {index = 2}, 5, 0)
    divisions.assign(1, 1, {a, b})
    local r = route(1, square)
    patrol.start(1, 1)
    assert(r.posts[a.unit_number] and not r.posts[b.unit_number] and b.command == nil)
    assert(r.posts[a.unit_number].loop, 'a lone soldier does not walk the whole route')
  end)

  test('patrol posts: a route saved with a leader is dealt posts on the next sweep', function()
    local a, b = soldier(nil, nil, 5, 0), soldier(nil, nil, 9, 0)
    divisions.assign(1, 1, {a, b})
    local record = divisions.record(1, 1)
    record.mode = 'patrol'
    record.patrol = {waypoints = {{x = 0, y = 0}, {x = 100, y = 0}}, index = 2, members = {a.unit_number, b.unit_number},
      lanes = true, leader = a.unit_number, surface_index = 1}
    assert(patrol.advance(a.unit_number) == nil, 'a legacy leader advanced a route without posts')
    patrol.tick()
    local r = record.patrol
    assert(r.posts[a.unit_number] and r.posts[b.unit_number] and a.command and b.command)
    assert(r.leader == nil and r.members == nil and r.index == nil, 'legacy fields kept')
  end)

  local function alarm_setup()
    defines.command.attack = 3
    local members = {}
    for i = 1, 4 do members[i] = soldier(nil, nil, -200 + 100 * i, -200) end
    members[1].force.is_enemy = function(other) return other == 'enemy' end
    local hq = soldier(nil, nil, 0, 0)
    hq.name = 'tank-squad-headquarters'
    members[#members + 1] = hq
    divisions.assign(1, 1, members)
    local r = route(1, square)
    patrol.start(1, 1)
    return members, hq, r, soldier('enemy', nil, -100, -190)
  end

  test('patrol alarm: the rest of the division comes to help a soldier under attack', function()
    local members, hq, r, biter = alarm_setup()
    local victim, posted = members[1], hq.command
    patrol.on_damaged{entity = victim, cause = biter}
    for i = 2, 4 do
      local c = members[i].command
      assert(c.type == defines.command.attack_area and c.destination.x == victim.position.x, 'soldier ' .. i .. ' stayed')
      assert(c.radius == patrol.HELP_RADIUS and r.responders[members[i].unit_number])
    end
    assert(victim.command.type == defines.command.go_to_location, 'the victim was pulled off its own fight')
    assert(hq.command == posted, 'the unarmed headquarters was sent to fight')
    -- A helper back from the fight takes up its post again.
    local helper = members[2]
    helper.position = {x = -100, y = -190}
    patrol.advance(helper.unit_number, defines.behavior_result.success)
    assert(not r.responders[helper.unit_number] and helper.command.type == defines.command.go_to_location)
    assert(helper.command.destination == r.posts[helper.unit_number].anchor, 'the helper did not return to its post')
  end)

  test('patrol alarm: one call per route every few seconds, and only for enemies', function()
    local members, hq, r, biter = alarm_setup()
    local friend = soldier(nil, nil, 0, 0)
    local sent = 0
    for i = 2, 4 do members[i].commandable.set_command = function(c) sent = sent + 1; members[i].command = c end end
    patrol.on_damaged{entity = members[1], cause = friend}
    patrol.on_damaged{entity = members[1]}
    assert(sent == 0, 'friendly fire or damage without a cause raised the alarm')
    patrol.on_damaged{entity = hq, cause = biter}
    assert(sent == 4 - 1, 'an attack on the headquarters did not call the soldiers')
    patrol.on_damaged{entity = members[2], cause = biter}
    assert(sent == 3, 'the alarm was raised again within the same seconds')
    game.tick = patrol.ALARM_TICKS
    patrol.on_damaged{entity = members[2], cause = biter}
    assert(sent == 3, 'helpers still on their way were called again')
    game.tick = patrol.RESPONSE_TICKS
    patrol.on_damaged{entity = members[2], cause = biter}
    assert(sent == 5, 'helpers that never reported back were not called again')
    divisions.record(1, 1).mode = 'idle'
    game.tick = 2 * patrol.RESPONSE_TICKS
    patrol.on_damaged{entity = members[2], cause = biter}
    assert(sent == 5, 'a division off patrol answered the alarm')
    assert(r)
  end)

  local function depot(x, y)
    local b = ctx.building()
    b.position = {x = x, y = y}
    return b
  end

  local function patrol_of(n, count)
    local members = {}
    for i = 1, count do members[i] = soldier(nil, nil, -200 + 10 * i, -200) end
    divisions.assign(1, n, members)
    local r = route(n, square)
    patrol.start(1, n)
    return members, r
  end

  test('patrol retreat: an injured soldier drives to the nearest barracks and leaves its post', function()
    depot(-250, -250)
    local members, r = patrol_of(1, 3)
    local hurt = members[1]
    hurt.health = 60
    patrol.tick()
    assert(retreat.is_away(r, hurt.unit_number), 'the injured soldier stayed')
    assert(hurt.command.destination.x == -250, 'not sent to the barracks')
    assert(r.dirty, 'posts not marked for a new deal')
    patrol.tick()
    assert(not r.posts[hurt.unit_number], 'the away soldier kept a post')
    assert(r.posts[members[2].unit_number] and r.posts[members[3].unit_number], 'the others lost their posts')
    assert(hurt.command.destination.x == -250, 'the new deal sent the injured soldier back to the route')
  end)

  test('patrol retreat: guards go only with more than ten soldiers, never the headquarters or a responder', function()
    depot(-250, -250)
    local function guards(n, count)
      local members = {}
      for i = 1, count do
        members[i] = soldier(nil, nil, -200 + 10 * i, -200)
        members[i].health = 300
      end
      local hq = soldier(nil, nil, 0, 0)
      hq.name = 'tank-squad-headquarters'
      members[#members + 1] = hq
      divisions.assign(1, n, members)
      local r = route(n, square)
      patrol.start(1, n)
      members[1].health = 60
      members[2].health = 400
      r.responders = {[members[2].unit_number] = game.tick}
      patrol.tick()
      assert(not retreat.is_away(r, hq.unit_number), 'the headquarters left')
      assert(not retreat.is_away(r, members[2].unit_number), 'a responder was sent as a guard')
      local away = 0
      for _, e in ipairs(members) do if retreat.is_away(r, e.unit_number) then away = away + 1 end end
      return away - 1
    end
    assert(guards(1, 10) == 0, 'ten soldiers and a headquarters sent a guard')
    assert(guards(2, 11) == 1, 'eleven soldiers did not send one guard')
  end)

  test('patrol retreat: a healed soldier rejoins and takes up a post', function()
    depot(-250, -250)
    local members, r = patrol_of(1, 3)
    local hurt = members[1]
    hurt.health = 60
    patrol.tick()
    patrol.tick()
    assert(not r.posts[hurt.unit_number])
    hurt.position = {x = -250, y = -248}
    hurt.health = 400
    patrol.tick()
    assert(not retreat.is_away(r, hurt.unit_number) and r.dirty, 'the healed soldier did not rejoin')
    patrol.tick()
    local post = r.posts[hurt.unit_number]
    assert(post and hurt.command.destination == post.anchor, 'the healed soldier got no post')
  end)

  test('patrol retreat: restarting a patrol forgets an interrupted retreat', function()
    depot(-250, -250)
    local members, r = patrol_of(1, 3)
    members[1].health = 60
    patrol.tick()
    assert(retreat.is_away(r, members[1].unit_number), 'the injured soldier stayed')
    divisions.record(1, 1).mode = 'idle'
    members[1].health = 400
    patrol.start(1, 1)
    assert(r.retreat == nil, 'restart kept the retreat state')
    assert(r.posts[members[1].unit_number], 'restart left the soldier without a post')
  end)

  test('patrol retreat: an injured soldier with no depot in reach keeps its post without new deals', function()
    local members, r = patrol_of(1, 3)
    members[1].health = 60
    local sent = 0
    for _, e in ipairs(members) do e.commandable.set_command = function(c) sent = sent + 1; e.command = c end end
    for _ = 1, 3 do patrol.tick() end
    assert(sent == 0 and not r.dirty, 'a soldier with nowhere to heal caused new orders')
    assert(not retreat.is_away(r, members[1].unit_number))
  end)

  test('patrol retreat: a patrol of only a headquarters never retreats', function()
    depot(-250, -250)
    local hq = soldier(nil, nil, 0, 0)
    hq.name = 'tank-squad-headquarters'
    divisions.assign(1, 1, {hq})
    local r = route(1, square)
    patrol.start(1, 1)
    hq.health = 60
    patrol.tick()
    assert(r.retreat == nil and not r.dirty, 'the headquarters retreated')
  end)

  test('patrol retreat: a failed leg\'s retry does not pull an away soldier back to the route', function()
    depot(-250, -250)
    local members, r = patrol_of(1, 3)
    local hurt = members[1]
    patrol.advance(hurt.unit_number, defines.behavior_result.fail)
    assert(r.retry and r.retry[hurt.unit_number], 'no retry pending')
    hurt.health = 60
    patrol.tick()
    assert(retreat.is_away(r, hurt.unit_number), 'the injured soldier stayed')
    assert(hurt.command.destination.x == -250, 'the retry sent the away soldier back to the route')
    assert(not (r.retry and r.retry[hurt.unit_number]), 'the retry was kept for an away soldier')
  end)

  test('patrol retreat: an away soldier that dies is dropped from its convoy', function()
    depot(-250, -250)
    local members, r = patrol_of(1, 3)
    local hurt = members[1]
    hurt.health = 60
    patrol.tick()
    patrol.tick()
    divisions.forget(hurt.unit_number)
    hurt.valid = false
    patrol.forget(hurt.unit_number)
    patrol.tick()
    assert(next(r.retreat.convoys) == nil, 'the convoy outlived its only soldier')
    assert(not retreat.is_away(r, hurt.unit_number), 'a dead soldier is still away')
  end)

  test('patrol retreat: one sweep reads the retreat settings once, however many patrols run', function()
    patrol_of(1, 3)
    patrol_of(2, 3)
    local global, reads = settings.global, 0
    settings.global = setmetatable({}, {__index = function(_, k) reads = reads + 1; return global[k] end})
    patrol.tick()
    settings.global = global
    local expected = #require('scripts.config').DEFINITIONS
    assert(reads == expected, 'settings read ' .. reads .. ' times, expected ' .. expected)
  end)

  test('patrol retreat: a healthy patrol sweep sends no orders and reads no positions', function()
    local members, r = patrol_of(1, 6)
    local reads, sent = {}, 0
    for i, e in ipairs(members) do
      reads[i] = ctx.count_reads(e, 'position')
      e.commandable.set_command = function(c) sent = sent + 1; e.command = c end
    end
    patrol.tick()
    for i = 1, 6 do assert(reads[i].n == 0, 'a healthy sweep read positions') end
    assert(sent == 0, 'a healthy sweep sent orders')
    assert(r.retreat and next(r.retreat.away) == nil)
  end)
end
