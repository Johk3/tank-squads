return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local divisions = require('scripts.divisions')
  local cover = require('scripts.cover')
  local commands = require('scripts.commands')
  local patrol = require('scripts.patrol')
  local escort = require('scripts.escort')
  local veterans = require('scripts.veterans')

  local function setup()
    dofile('control.lua')
    defines.distraction.none = defines.distraction.none or 0
    defines.command.attack = defines.command.attack or 3
    game.surfaces[1].find_units = function() return {} end
  end

  local function veteran(x, y, rank)
    local e = soldier(nil, nil, x, y)
    local record = veterans.register(e)
    record.rank, record.xp = rank or 3, 1000 * (rank or 3)
    return e
  end

  -- Every soldier has a service record from the moment it is built.
  local function private(x, y)
    local e = soldier(nil, nil, x, y)
    veterans.register(e)
    return e
  end

  local function recruits(count, x, y)
    local out = {}
    for i = 1, count do out[i] = private((x or 0) + i * 2, y or 0) end
    return out
  end

  local function with(list, extra)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e end
    for _, e in ipairs(extra or {}) do out[#out + 1] = e end
    return out
  end

  local function held(list)
    local count = 0
    for _, e in ipairs(list) do if cover.held(e.unit_number) then count = count + 1 end end
    return count
  end

  local function sweep()
    divisions.refresh()
    cover.tick()
  end

  local function badge_target(n)
    local marker = divisions.record(1, n).render.markers[1]
    return marker and marker.unit_number
  end

  test('cover: the flag goes to the highest-ranking soldier and stays on a tie', function()
    setup()
    local a, b, c = private(0, 0), veteran(5, 0, 3), veteran(10, 0, 3)
    divisions.assign(1, 2, {a, b, c})
    divisions.refresh()
    assert(badge_target(2) == b.unit_number, 'the flag did not go to the first veteran')
    veterans.get(c.unit_number).rank = 3
    divisions.refresh()
    assert(badge_target(2) == b.unit_number, 'a tie moved the flag')
    veterans.get(c.unit_number).rank = 5
    divisions.refresh()
    assert(badge_target(2) == c.unit_number, 'the Legend did not take the flag')
  end)

  test('cover: a veteran takes nearby soldiers as covers at its sides', function()
    setup()
    local v, others = veteran(0, 0), recruits(4)
    divisions.assign(1, 1, with({v}, others))
    sweep()
    assert(held(others) == 4, 'expected four covers, got ' .. held(others))
    assert(not cover.held(v.unit_number), 'the veteran itself is held')
    for _, e in ipairs(others) do
      local c = e.command
      assert(c and c.type == defines.command.go_to_location, 'a cover was not sent to its spot')
      local dx, dy = c.destination.x - v.position.x, c.destination.y - v.position.y
      assert(math.abs(math.sqrt(dx * dx + dy * dy) - cover.SPACING) < 1e-6, 'a cover spot is off the veteran')
    end
    -- The veteran stands still, so nobody is sent again.
    for _, e in ipairs(others) do e.command = nil end
    game.tick = 60
    sweep()
    for _, e in ipairs(others) do assert(e.command == nil, 'a cover was sent again for nothing') end
    -- It moves: the covers follow.
    v.position = {x = 20, y = 0}
    game.tick = 120
    sweep()
    for _, e in ipairs(others) do assert(e.command and e.command.destination.x > 10, 'a cover did not follow') end
  end)

  test('cover: at most five covers, shared between veterans by rank', function()
    setup()
    local legend, vet = veteran(0, 0, 5), veteran(0, 10, 3)
    local others = recruits(9)
    divisions.assign(1, 1, with({legend, vet}, others))
    sweep()
    assert(held(others) == 8, 'nine soldiers for two veterans should give four covers each, got ' .. held(others))
    local lone, many = veteran(100, 100), recruits(12, 100, 100)
    divisions.assign(1, 3, with({lone}, many))
    sweep()
    assert(held(many) == cover.MAX_COVERS, 'more than five covers')
  end)

  test('cover: a large division recruits covers without a pool scan per veteran', function()
    setup()
    -- 1200 soldiers 3 tiles apart in a square, every third a veteran.
    local list = {}
    for i = 1, 1200 do
      local x, y = (i % 35) * 3, math.floor(i / 35) * 3
      list[i] = i % 3 == 0 and veteran(x, y, 3) or private(x, y)
    end
    divisions.assign(1, 1, list)
    divisions.refresh()
    local reads = {}
    for i, e in ipairs(list) do reads[i] = ctx.count_reads(e, 'position') end
    cover.tick()
    local total = 0
    for _, r in ipairs(reads) do total = total + r.n end
    assert(held(list) > 400, 'test setup: only ' .. held(list) .. ' covers')
    assert(total <= 3 * 1200, total .. ' position reads to cover 400 veterans')
  end)

  test('cover: a small or spread-out division gives no covers', function()
    setup()
    local v, one = veteran(0, 0), private(3, 0)
    divisions.assign(1, 1, {v, one})
    sweep()
    assert(not cover.held(one.unit_number), 'a single soldier became a cover')
    local w = veteran(500, 0)
    local far = {private(500 + cover.REACH + 5, 0), private(500, cover.REACH + 5), private(500 - cover.REACH - 5, 0)}
    divisions.assign(1, 2, with({w}, far))
    sweep()
    assert(held(far) == 0, 'distant soldiers became covers')
  end)

  test('cover: a lone veteran calls for help and falls back behind its helpers', function()
    setup()
    local v = veteran(0, 0)
    local helpers = {private(0, 80), private(5, 80), private(-5, 80)}
    local enemies = {}
    for i = 1, cover.DANGER_COUNT do
      local e = soldier('enemy', nil, i, -30)
      e.type = 'unit'
      enemies[i] = e
    end
    game.surfaces[1].find_units = function() return enemies end
    divisions.assign(1, 1, with({v}, helpers))
    commands.order(1, {left_top = {x = 0, y = 0}, right_bottom = {x = 2, y = 2}}, game.surfaces[1])
    sweep()
    sweep()
    assert(held(helpers) == 3, 'helpers were not called')
    for _, h in ipairs(helpers) do
      local c = h.command
      assert(c and c.type == defines.command.attack_area and c.destination.y == -30, 'a helper did not attack')
    end
    local c = v.command
    assert(c.type == defines.command.go_to_location and c.distraction == defines.distraction.none,
      'the veteran did not fall back')
    assert(c.destination.y > 80, 'the veteran did not get behind the helpers: ' .. c.destination.y)
    assert(cover.held(v.unit_number), 'the veteran is not held while it falls back')
    local flying = ctx.players()[1].flying
    assert(flying[#flying].text[1] == 'tank-squads.cover-call', 'no call for help shown')
    -- Completions stop at the call.
    assert(cover.on_command_completed(v.unit_number), 'the veteran completion reached its job')
    -- The enemies leave: after the calm sweeps everyone takes up the order.
    game.surfaces[1].find_units = function() return {} end
    for i = 1, cover.CALM_SWEEPS do
      game.tick = i * 60
      sweep()
    end
    assert(held(helpers) == 0 and not cover.held(v.unit_number), 'the call did not end')
    assert(v.command.destination.x == 1, 'the veteran did not take up its order again')
    for _, h in ipairs(helpers) do
      assert(cover.held(h.unit_number) or h.command.destination.x == 1, 'a helper did not take up the order again')
    end
    -- No new call during the cooldown.
    game.surfaces[1].find_units = function() return enemies end
    game.tick = game.tick + 60
    sweep()
    assert(not cover.held(v.unit_number), 'called again during the cooldown')
  end)

  test('cover: a veteran with cover does not call for help', function()
    setup()
    local v, others = veteran(0, 0), recruits(3)
    local enemies = {}
    for i = 1, cover.DANGER_COUNT do enemies[i] = soldier('enemy', nil, i, -30) end
    divisions.assign(1, 1, with({v}, others))
    local searched = 0
    game.surfaces[1].find_units = function() searched = searched + 1; return enemies end
    sweep()
    assert(not cover.held(v.unit_number) and searched == 0, 'a covered veteran looked for danger')
  end)

  test('cover: a veteran that dies gives its covers their job back', function()
    setup()
    local v, others = veteran(0, 0), recruits(3)
    divisions.assign(1, 1, with({v}, others))
    commands.order(1, {left_top = {x = 40, y = 40}, right_bottom = {x = 42, y = 42}}, game.surfaces[1])
    sweep()
    sweep()
    assert(held(others) == 3, 'no covers')
    ctx.handlers().on_entity_died{entity = v}
    v.valid = false
    assert(held(others) == 0, 'covers still held after their veteran died')
    for _, e in ipairs(others) do assert(e.command.destination.x == 41, 'a cover did not take up the order') end
  end)

  test('cover: a new order lets every held soldier go', function()
    setup()
    local v, others = veteran(0, 0), recruits(3)
    divisions.assign(1, 1, with({v}, others))
    sweep()
    assert(held(others) == 3)
    commands.order(1, {left_top = {x = 40, y = 40}, right_bottom = {x = 42, y = 42}}, game.surfaces[1])
    for _, e in ipairs(others) do assert(e.command.destination.x == 41, 'the order skipped a cover') end
    sweep()
    assert(held(others) == 0, 'covers kept after a new order')
    for _, e in ipairs(others) do assert(e.command.destination.x == 41, 'releasing replaced the order') end
    sweep()
    assert(held(others) == 3, 'covers not taken again under the new order')
  end)

  test('cover: patrol posts leave covers out and deal them back when let go', function()
    setup()
    local v, others = veteran(0, 0), recruits(3)
    divisions.assign(1, 1, with({v}, others))
    patrol.add_waypoint(1, 1, {x = 0, y = 0}, game.surfaces[1])
    patrol.add_waypoint(1, 1, {x = 100, y = 0}, game.surfaces[1])
    patrol.start(1, 1)
    sweep()
    sweep()
    assert(held(others) == 3, 'no covers on patrol')
    patrol.tick()
    local posts = divisions.record(1, 1).patrol.posts
    for _, e in ipairs(others) do assert(not posts[e.unit_number], 'a cover kept a patrol post') end
    assert(posts[v.unit_number], 'the veteran lost its post')
    -- A cover's completion does not move it along the route.
    ctx.handlers().on_ai_command_completed{unit_number = others[1].unit_number, result = defines.behavior_result.success}
    assert(patrol.index(1, 1, others[1].unit_number) == nil, 'a cover advanced on the route')
    -- The veteran loses its rank: the covers go back to the patrol.
    veterans.get(v.unit_number).rank = 2
    sweep()
    assert(held(others) == 0, 'covers kept without a veteran')
    patrol.tick()
    posts = divisions.record(1, 1).patrol.posts
    for _, e in ipairs(others) do assert(posts[e.unit_number], 'a former cover got no post') end
  end)

  test('cover: an escort leaves covers out of its formation', function()
    setup()
    local v, others = veteran(0, 0), recruits(3)
    divisions.assign(1, 1, with({v}, others))
    escort.start(1, 1, 1, 'offensive')
    sweep()
    sweep()
    assert(held(others) == 3, 'no covers on escort')
    for _, e in ipairs(others) do e.command = nil end
    local state = divisions.record(1, 1).escort
    state.anchor = {x = 0, y = 0}
    ctx.players()[1].character = {valid = true, surface_index = 1, position = {x = 0, y = 0}}
    game.surfaces[1].find_nearest_enemy = function() return nil end
    local force = ctx.players()[1].force
    force.chart = force.chart or function() end
    escort.tick()
    assert(state.leg and state.leg.leader == v.unit_number, 'a cover led the leg')
    for _, e in ipairs(others) do assert(e.command == nil, 'the escort commanded a cover') end
  end)

  test('cover: a scouting division holds nobody', function()
    setup()
    local v, others = veteran(0, 0), recruits(3)
    divisions.assign(1, 1, with({v}, others))
    sweep()
    assert(held(others) == 3)
    divisions.record(1, 1).mode = 'scout'
    sweep()
    assert(held(others) == 0, 'scouting kept covers')
  end)

  test('cover: a division without veterans costs no cover state', function()
    setup()
    divisions.assign(1, 1, recruits(4))
    sweep()
    assert(not next(storage.cover.divisions), 'a division without veterans got cover state')
  end)

  test('cover: a call lasts while the fight goes on, even with the veteran safe', function()
    setup()
    local v = veteran(0, 0)
    local helpers = {private(0, 80), private(5, 80), private(-5, 80)}
    local enemies = {}
    for i = 1, cover.DANGER_COUNT do enemies[i] = soldier('enemy', nil, i, -30) end
    game.surfaces[1].find_units = function(q)
      local out, a, b = {}, q.area[1], q.area[2]
      for _, e in ipairs(enemies) do
        local p = e.position
        if p.x >= a[1] and p.x <= b[1] and p.y >= a[2] and p.y <= b[2] then out[#out + 1] = e end
      end
      return out
    end
    divisions.assign(1, 1, with({v}, helpers))
    sweep()
    assert(cover.held(v.unit_number), 'no call')
    v.position = {x = 0, y = 92}
    for i = 1, cover.CALM_SWEEPS + 2 do
      game.tick = i * 60
      sweep()
    end
    assert(cover.held(v.unit_number) and held(helpers) == 3, 'the call ended while the enemies were still there')
    enemies = {}
    for i = 1, cover.CALM_SWEEPS do
      game.tick = game.tick + 60
      sweep()
    end
    assert(not cover.held(v.unit_number), 'the call did not end once the enemies were gone')
  end)

  test('cover: a stuck cover far away is let go, a following one is kept', function()
    setup()
    local v, others = veteran(0, 0), recruits(3)
    divisions.assign(1, 1, with({v}, others))
    sweep()
    assert(held(others) == 3)
    -- The veteran runs ahead; one cover is still walking, one gave up.
    v.position = {x = 200, y = 0}
    others[1].position = {x = 20, y = 0}
    others[2].position = {x = 20, y = 5}
    game.tick = cover.AUDIT_TICKS
    sweep()
    ctx.handlers().on_ai_command_completed{unit_number = others[2].unit_number, result = defines.behavior_result.fail}
    game.tick = 2 * cover.AUDIT_TICKS
    sweep()
    assert(cover.held(others[1].unit_number), 'a following cover was let go')
    assert(not cover.held(others[2].unit_number), 'a stuck cover was kept')
  end)
end
