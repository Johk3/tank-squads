return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local retreat = require('scripts.retreat')
  local names = require('scripts.names')
  local hq_module = require('scripts.headquarters')

  local function context(over)
    local c = {force = game.players[1].force, surface_index = 1, retreat = 0.35, rejoin = 0.95, range = 1000,
      rejoined = {}}
    c.on_rejoin = function(soldier) c.rejoined[#c.rejoined + 1] = soldier end
    for k, v in pairs(over or {}) do c[k] = v end
    return c
  end

  local function depot(x, y)
    local b = building()
    b.position = {x = x, y = y}
    return b
  end

  -- A registered headquarters without its helpers: retreats only read the
  -- registry and the unit itself.
  local function headquarters(x, y)
    local e = soldier(nil, nil, x, y)
    e.name = names.headquarters
    storage.headquarters = storage.headquarters or {}
    storage.headquarters[e.unit_number] = {entity = e, force_index = e.force_index, helpers = {}}
    return e
  end

  local function squad(count)
    local out = {}
    for i = 1, count do out[i] = soldier(nil, nil, 0, i) end
    return out
  end

  test('retreat: a soldier below the threshold walks to the nearest barracks', function()
    depot(50, 0)
    depot(300, 0)
    local members = squad(3)
    members[1].health = 139 -- 34.75 %
    members[2].health = 140 -- exactly 35 %: stays
    local state = {}
    local present, changed = retreat.sweep(state, members, context())
    assert(changed and #present == 2, 'wrong present count')
    assert(retreat.is_away(state, members[1].unit_number) and not retreat.is_away(state, members[2].unit_number))
    local c = members[1].command
    assert(c.type == defines.command.go_to_location and c.destination.x == 50, 'not sent to the nearest barracks')
    assert(c.radius == retreat.ARRIVAL_RADIUS and c.distraction == defines.distraction.by_enemy)
    assert(members[2].command == nil and members[3].command == nil, 'healthy soldiers got orders')
  end)

  test('retreat: barracks of another force, on another surface or out of range are ignored', function()
    depot(20, 0).force = {}
    depot(30, 0).surface_index = 2
    depot(1500, 0)
    local members = squad(1)
    members[1].health = 50
    local state = {}
    local present, changed = retreat.sweep(state, members, context())
    assert(not changed and #present == 1 and members[1].command == nil, 'retreated without a reachable barracks')
    depot(900, 0)
    present = retreat.sweep(state, members, context())
    assert(#present == 0 and members[1].command.destination.x == 900)
  end)

  test('retreat: injured soldiers sharing a barracks form one convoy', function()
    depot(-100, 0)
    depot(100, 0)
    local members = {soldier(nil, nil, -10, 0), soldier(nil, nil, -12, 0), soldier(nil, nil, 10, 0), soldier(nil, nil, 40, 0)}
    for i = 1, 3 do members[i].health = 60 end
    local state = {}
    retreat.sweep(state, members, context())
    local count = 0
    for _ in pairs(state.retreat.convoys) do count = count + 1 end
    assert(count == 2, 'expected one convoy per barracks, got ' .. count)
    local away = state.retreat.away
    assert(away[members[1].unit_number] == away[members[2].unit_number], 'west pair split up')
    assert(away[members[1].unit_number] ~= away[members[3].unit_number], 'east soldier joined the west convoy')
    assert(not away[members[4].unit_number], 'no guards below 11 soldiers')
  end)

  test('retreat: guard count follows division size', function()
    depot(100, 0)
    for _, case in ipairs({{10, 0}, {11, 1}, {21, 2}}) do
      local members = squad(case[1])
      members[1].health = 60
      local present = retreat.sweep({}, members, context())
      local guards = case[1] - 1 - #present
      assert(guards == case[2], case[1] .. ' soldiers sent ' .. guards .. ' guards')
    end
  end)

  test('retreat: guards are the healthiest candidates, never a responder or the leg leader', function()
    depot(100, 0)
    local members = squad(12)
    for i = 2, 12 do members[i].health = 300 end
    members[1].health = 60
    members[3].health = 395
    members[4].health = 399 -- active responder
    members[5].health = 398 -- offensive leg leader
    members[6].health = 395 -- ties with 3; 3 has the lower unit number
    local state = {}
    retreat.sweep(state, members, context({responders = {[members[4].unit_number] = false},
      leader = members[5].unit_number}))
    local away = state.retreat.away
    assert(away[members[3].unit_number], 'healthiest free soldier not chosen as guard')
    assert(not away[members[4].unit_number] and not away[members[5].unit_number], 'responder or leader sent as guard')
    assert(not away[members[6].unit_number], 'tie not broken by unit number')
    assert(members[3].command.destination.x == 100, 'guard not sent to the barracks')
  end)

  test('retreat: a healed soldier rejoins and guards return with the last injured', function()
    depot(100, 0)
    local members = squad(11)
    members[1].health, members[2].health = 60, 60
    local c, state = context(), {}
    local present = retreat.sweep(state, members, c)
    assert(#present == 8, 'expected 2 injured and 1 guard away')
    members[1].health = 380 -- exactly 95 %
    local changed
    present, changed = retreat.sweep(state, members, c)
    assert(changed and #present == 9 and c.rejoined[1] == members[1], 'healed soldier did not rejoin')
    members[2].health = 400
    present = retreat.sweep(state, members, c)
    assert(#present == 11 and next(state.retreat.convoys) == nil, 'guard kept after the last injured healed')
  end)

  test('retreat: guards return when their injured die or leave the division', function()
    depot(100, 0)
    local members = squad(11)
    members[1].health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    local remaining = {}
    for i = 2, 11 do remaining[#remaining + 1] = members[i] end
    local present, changed = retreat.sweep(state, remaining, c)
    assert(changed and #present == 10, 'guard stayed away without injured')
    assert(next(state.retreat.convoys) == nil and next(state.retreat.away) == nil, 'stale convoy state')
  end)

  test('retreat: a destroyed barracks re-routes the convoy, or ends it when none is left', function()
    local first, second = depot(50, 0), depot(200, 0)
    local members = squad(2)
    members[1].health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    first.valid = false
    retreat.sweep(state, members, c)
    assert(members[1].command.destination.x == 200 and retreat.is_away(state, members[1].unit_number),
      'convoy not re-routed')
    second.valid = false
    local present, changed = retreat.sweep(state, members, c)
    assert(changed and #present == 2, 'convoy kept without a barracks')
    assert(state.retreat.cooldown[members[1].unit_number], 'unhealed soldier got no retry cooldown')
  end)

  test('retreat: a stuck convoy rejoins after the timeout and waits out the cooldown', function()
    depot(100, 0)
    local members = squad(1)
    members[1].health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    game.tick = game.tick + retreat.TIMEOUT
    local present = retreat.sweep(state, members, c)
    assert(#present == 1, 'stuck convoy never rejoined')
    game.tick = game.tick + 60
    present = retreat.sweep(state, members, c)
    assert(#present == 1, 'retreated again during the cooldown')
    game.tick = game.tick + retreat.TIMEOUT
    present = retreat.sweep(state, members, c)
    assert(#present == 0, 'cooldown never expired')
  end)

  test('retreat: a convoy still closing in or healing is not timed out', function()
    depot(900, 0)
    local members = squad(1)
    local a = members[1]
    a.health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    for step = 1, 20 do
      a.position = {x = step * 44, y = 1}
      game.tick = game.tick + 600
      retreat.sweep(state, members, c)
    end
    assert(retreat.is_away(state, a.unit_number), 'a long walk that kept closing in was cut short')
    a.position = {x = 895, y = 1}
    game.tick = game.tick + retreat.TIMEOUT
    retreat.sweep(state, members, c)
    game.tick = game.tick + retreat.TIMEOUT
    retreat.sweep(state, members, c)
    assert(retreat.is_away(state, a.unit_number), 'a soldier healing at the barracks was sent back')
  end)

  test('retreat: an away soldier pushed out of healing range is sent back, only after a completion', function()
    depot(100, 0)
    local members = squad(1)
    local a = members[1]
    a.health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    a.position, a.command = {x = 130, y = 0}, nil
    retreat.sweep(state, members, c)
    assert(a.command == nil, 'resent while the soldier may still be walking')
    retreat.on_command_completed(state, a.unit_number, defines.behavior_result.success)
    retreat.sweep(state, members, c)
    assert(a.command and a.command.destination.x == 100, 'displaced soldier not sent back to the barracks')
    a.position, a.command = {x = 102, y = 0}, nil
    retreat.on_command_completed(state, a.unit_number, defines.behavior_result.success)
    retreat.sweep(state, members, c)
    assert(a.command == nil, 'resent a soldier already at the barracks')
  end)

  test('retreat: repeated failed paths to the barracks end the convoy', function()
    depot(100, 0)
    local members = squad(1)
    local a = members[1]
    a.health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    retreat.on_command_completed(state, a.unit_number, defines.behavior_result.fail)
    retreat.sweep(state, members, c)
    assert(retreat.is_away(state, a.unit_number), 'one failed path ended the convoy')
    retreat.on_command_completed(state, a.unit_number, defines.behavior_result.fail)
    local present = retreat.sweep(state, members, c)
    assert(#present == 1 and state.retreat.cooldown[a.unit_number], 'unreachable barracks kept the convoy out')
  end)

  test('retreat: injured soldiers with no barracks in reach read each barracks once per sweep', function()
    local far = {depot(5000, 0), depot(6000, 0), depot(7000, 0)}
    local reads = {}
    for i, b in ipairs(far) do reads[i] = ctx.count_reads(b, 'position') end
    local members = squad(5)
    for _, e in ipairs(members) do e.health = 60 end
    retreat.sweep({}, members, context())
    for i = 1, 3 do assert(reads[i].n <= 1, 'barracks position read ' .. reads[i].n .. ' times in one sweep') end
  end)

  test('retreat: a healthy division issues no orders and reads no positions', function()
    depot(100, 0)
    local members = squad(5)
    local reads = ctx.count_reads(members[1], 'position')
    local present, changed = retreat.sweep({}, members, context())
    assert(present == members and not changed and reads.n == 0, 'healthy sweep did extra work')
    for _, e in ipairs(members) do assert(e.command == nil, 'healthy soldier got an order') end
    assert(retreat.is_away({}, members[1].unit_number) == false)
  end)

  test('retreat: a sweep returns the summed health of the soldiers that stay', function()
    depot(100, 0)
    local members = squad(3)
    members[2].health = 300
    members[3].health = 100 -- 25 %: leaves in a convoy
    local present, _, health, max_health = retreat.sweep({}, members, context())
    assert(#present == 2 and health == 700 and max_health == 800, 'sums ' .. tostring(health) .. '/' .. tostring(max_health))
    present, _, health, max_health = retreat.sweep({}, squad(2), context())
    assert(health == 800 and max_health == 800, 'healthy sums wrong')
  end)

  test('retreat: exported barracks lookup finds the nearest barracks in range', function()
    depot(50, 0)
    depot(300, 0)
    local list = retreat.barracks_in_reach(context())
    local i, distance = retreat.nearest_barracks(list, {x = 0, y = 0}, 1000)
    assert(list[i].position.x == 50 and distance == 50, 'wrong nearest barracks')
    assert(retreat.nearest_barracks(list, {x = 0, y = 0}, 10) == nil, 'barracks out of range found')
  end)

  test('retreat: absorbed convoys keep going and rejoin the new state', function()
    depot(100, 0)
    local a, b = squad(2), squad(2)
    a[1].health, b[1].health = 60, 60
    local from, into = {}, {}
    local c = context()
    retreat.sweep(from, a, c)
    retreat.sweep(into, b, c)
    from.retreat.cooldown[a[2].unit_number] = game.tick + 50
    retreat.absorb(into, from)
    assert(from.retreat == nil, 'source state kept its convoys')
    local ids = {}
    for id in pairs(into.retreat.convoys) do ids[#ids + 1] = id end
    assert(#ids == 2 and ids[1] ~= ids[2], 'convoy ids collided')
    local moved = into.retreat.away[a[1].unit_number]
    assert(moved and into.retreat.convoys[moved].injured[a[1].unit_number], 'away mark lost its convoy')
    assert(into.retreat.cooldown[a[2].unit_number], 'cooldown lost')
    a[1].health = 400
    local all = {a[1], a[2], b[1], b[2]}
    retreat.sweep(into, all, c)
    assert(not retreat.is_away(into, a[1].unit_number), 'healed soldier of an absorbed convoy did not rejoin')
    local rejoined = false
    for _, s in ipairs(c.rejoined) do if s == a[1] then rejoined = true end end
    assert(rejoined, 'rejoin went to the wrong state')
    retreat.absorb(into, {})
    local empty = {}
    retreat.absorb(empty, into)
    assert(empty.retreat and empty.retreat.next_id >= 2, 'absorb did not create the target state')
  end)
  test('retreat: an injured soldier drives to a headquarters nearer than any barracks', function()
    depot(300, 0)
    headquarters(80, 0)
    local members = squad(1)
    members[1].health = 60
    retreat.sweep({}, members, context())
    local c = members[1].command
    assert(c.destination.x == 80, 'not sent to the nearer headquarters')
    assert(c.radius == retreat.HQ_ARRIVAL_RADIUS, 'wrong arrival radius for a headquarters')
  end)

  test('retreat: a barracks nearer than the headquarters still wins', function()
    depot(60, 0)
    headquarters(200, 0)
    local members = squad(1)
    members[1].health = 60
    retreat.sweep({}, members, context())
    assert(members[1].command.destination.x == 60 and members[1].command.radius == retreat.ARRIVAL_RADIUS,
      'not sent to the nearer barracks')
  end)

  test('retreat: headquarters of another force or on another surface are ignored', function()
    headquarters(20, 0).force = {}
    headquarters(30, 0).surface_index = 2
    local members = squad(1)
    members[1].health = 60
    local present = retreat.sweep({}, members, context())
    assert(#present == 1 and members[1].command == nil, 'retreated to a foreign headquarters')
  end)

  test('retreat: a convoy follows its headquarters once it moved a few tiles', function()
    local hq = headquarters(100, 0)
    local members = squad(1)
    local a = members[1]
    a.health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    a.command = nil
    hq.position = {x = 100 + retreat.FOLLOW_STEP - 1, y = 0}
    retreat.sweep(state, members, c)
    assert(a.command == nil, 'resent for a small headquarters step')
    hq.position = {x = 130, y = 0}
    retreat.sweep(state, members, c)
    assert(a.command and a.command.destination.x == 130, 'convoy did not follow the headquarters')
    a.position, a.command = {x = 135, y = 0}, nil
    hq.position = {x = 140, y = 0}
    retreat.sweep(state, members, c)
    assert(a.command == nil, 'resent a soldier already beside the headquarters')
  end)

  test('retreat: a soldier within the headquarters healing reach is not timed out', function()
    headquarters(100, 0)
    local members = squad(1)
    local a = members[1]
    a.health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    a.position = {x = 100 - hq_module.HEAL_RADIUS + 2, y = 0}
    for _ = 1, 3 do
      game.tick = game.tick + retreat.TIMEOUT
      retreat.sweep(state, members, c)
    end
    assert(retreat.is_away(state, a.unit_number), 'a soldier healing at the headquarters was sent back')
  end)

  test('retreat: a lost headquarters re-routes the convoy to a barracks', function()
    local hq = headquarters(50, 0)
    depot(200, 0)
    local members = squad(1)
    members[1].health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    hq.valid = false
    retreat.sweep(state, members, c)
    local command = members[1].command
    assert(command.destination.x == 200 and command.radius == retreat.ARRIVAL_RADIUS, 'convoy not re-routed')
  end)

  test('retreat: convoys saved before headquarters existed keep going to their barracks', function()
    depot(100, 0)
    local members = squad(1)
    members[1].health = 60
    local c, state = context(), {}
    retreat.sweep(state, members, c)
    for _, convoy in pairs(state.retreat.convoys) do convoy.mobile = nil end
    members[1].position, members[1].command = {x = 150, y = 0}, nil
    retreat.on_command_completed(state, members[1].unit_number, defines.behavior_result.success)
    retreat.sweep(state, members, c)
    assert(members[1].command.destination.x == 100 and members[1].command.radius == retreat.ARRIVAL_RADIUS)
  end)
end
