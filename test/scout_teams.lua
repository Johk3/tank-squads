return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local teams = require('scripts.scout_teams')
  local geometry = require('scripts.scout_geometry')
  local divisions = require('scripts.divisions')
  local scout = require('scripts.scout')
  local retreat = require('scripts.retreat')

  local NAMES = {siege = 'tank-squad-siege', flame = 'tank-squad-flame'}
  local function tank(kind, x, y)
    local e = soldier(nil, nil, x or 0, y or 0)
    if NAMES[kind] then e.name = NAMES[kind] end
    return e
  end
  local function squad(kinds)
    local out = {}
    for i, kind in ipairs(kinds) do out[i] = tank(kind, i * 2, 0) end
    return out
  end
  local function by_id(list)
    local out = {}
    for _, e in ipairs(list) do out[e.unit_number] = e end
    return out
  end
  local cfg = {retreat = 0.35, rejoin = 0.95, range = 1000}
  -- A search stub: returns `result` for every call and counts the calls.
  local function context(list, result, empty)
    local c = {by_id = by_id(list), force = game.players[1].force, surface = game.surfaces[1], cfg = cfg, calls = 0}
    c.search = function() c.calls = c.calls + 1; return result, empty end
    return c
  end
  local function forward(hop, e)
    local d = e.command.destination
    return (d.x - hop.point.x) * hop.heading.x + (d.y - hop.point.y) * hop.heading.y
  end
  local success, fail = function() return defines.behavior_result.success end, function() return defines.behavior_result.fail end

  test('scout teams: forming deals kinds into teams and indexes every member', function()
    local list = squad({'carrier', 'carrier', 'carrier', 'carrier', 'flame', 'siege'})
    local state = {surface_index = 1}
    teams.form(state, list)
    assert(state.team_count == 2, 'expected 2 teams, got ' .. state.team_count)
    local siege, flame = list[6].unit_number, list[5].unit_number
    assert(state.team_of[siege] == 1 and state.team_of[flame] == 2, 'siege and flame not dealt first')
    for _, e in ipairs(list) do assert(state.team_of[e.unit_number], 'member not indexed') end
    assert(#state.teams[1].members == 3 and state.teams[1].formed == 3)
    assert(math.abs(state.origin.x - 7) < 1e-6 and state.origin.y == 0, 'origin is not the centroid')
  end)

  test('scout teams: a hop sends each soldier once to its formation slot', function()
    local list = squad({'carrier', 'carrier', 'siege'})
    local state = {surface_index = 1}
    teams.form(state, list)
    teams.sweep(state, 1, context(list, {x = 10, y = 0}))
    local team = state.teams[1]
    local hop = team.hop
    assert(hop and team.target.x == 10, 'no hop towards the target')
    assert(math.abs(geometry.distance(hop.point, {x = 4, y = 0}) - geometry.HOP) < 1e-6, 'hop is not 32 tiles')
    assert(math.abs(forward(hop, list[3]) + geometry.TRAIL) < 1e-6 and list[3].command.radius == 6, 'siege not trailing')
    assert(math.abs(forward(hop, list[1])) < 1e-6 and list[1].command.radius == 4, 'carrier not at the front')
    assert(hop.front[list[1].unit_number] and not hop.front[list[3].unit_number], 'front band wrong')
    for _, e in ipairs(list) do assert(hop.pending[e.unit_number], 'member not pending') end
  end)

  test('scout teams: a hop ends only when every member arrived or the timeout passed', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local first = state.teams[1].hop
    teams.on_command_completed(state, list[1].unit_number, success())
    teams.on_command_completed(state, list[2].unit_number, success())
    local order = list[1].command
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop == first and list[1].command == order, 'hop ended with a member still walking')
    teams.on_command_completed(state, list[3].unit_number, success())
    teams.sweep(state, 1, c)
    local second = state.teams[1].hop
    assert(second ~= first and second.from.x == first.point.x, 'next hop did not start from the last hop point')
    game.tick = game.tick + geometry.HOP_TIMEOUT
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop ~= second, 'timed-out hop did not end')
  end)

  test('scout teams: the target changes only at the end of a hop', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local force = game.players[1].force
    force.chart(nil, {{x = 20 * 32, y = 0}, {x = 20 * 32 + 1, y = 1}})
    teams.sweep(state, 1, c)
    assert(state.teams[1].target.x == 20, 'target dropped mid-hop')
    c.search = function() return {x = 30, y = 0} end
    for _, e in ipairs(list) do teams.on_command_completed(state, e.unit_number, success()) end
    teams.sweep(state, 1, c)
    assert(state.teams[1].target.x == 30, 'a charted target was not replaced at the end of the hop')
  end)

  test('scout teams: a hop whose whole front failed blocks the chunk and keeps the team in place', function()
    local list = squad({'carrier', 'carrier', 'siege'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local hop = state.teams[1].hop
    teams.on_command_completed(state, list[1].unit_number, fail())
    teams.on_command_completed(state, list[2].unit_number, fail())
    teams.on_command_completed(state, list[3].unit_number, success())
    c.search = function() return {x = 25, y = 0} end
    teams.sweep(state, 1, c)
    local team = state.teams[1]
    assert(team.failed and team.failed['20:0'], 'failed chunk not blocked')
    assert(team.target.x == 25, 'no new target after the block')
    assert(team.hop.from.x == hop.from.x, 'the next hop did not start where the team stood')
  end)

  test('scout teams: an empty search starts a march and a found chunk ends it at the hop end', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, nil, true)
    teams.sweep(state, 1, c)
    local team = state.teams[1]
    assert(team.march == 1 and team.hop and not team.target, 'empty search did not march')
    assert(math.abs(team.hop.heading.x + 1) < 1e-6, 'first march angle is not the middle of the sector (west)')
    c.search = function() return {x = -9, y = 0} end
    teams.sweep(state, 1, c)
    assert(team.found and team.found.x == -9 and not team.target, 'march did not keep searching during the hop')
    for _, e in ipairs(list) do teams.on_command_completed(state, e.unit_number, success()) end
    teams.sweep(state, 1, c)
    assert(team.target and team.target.x == -9 and not team.march and not team.found, 'found chunk did not end the march')
  end)

  test('scout teams: five failed march angles block the team', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, nil, true)
    teams.sweep(state, 1, c)
    for round = 1, geometry.MARCH_ANGLES do
      assert(not state.teams[1].blocked, 'blocked after ' .. (round - 1) .. ' failed angles')
      for _, e in ipairs(list) do teams.on_command_completed(state, e.unit_number, fail()) end
      teams.sweep(state, 1, c)
    end
    assert(state.teams[1].blocked and teams.all_blocked(state), 'team not blocked after every march angle failed')
  end)

  test('scout teams: a joiner walks to the team and takes a slot only at the next hop', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local recruit = tank('carrier', 0, 5)
    assert(teams.join(state, recruit), 'join refused')
    local hop = state.teams[1].hop
    assert(recruit.command.destination.x == hop.point.x and recruit.command.radius == 8, 'recruit not sent to the hop point')
    assert(not hop.pending[recruit.unit_number], 'recruit stalls the hop')
    for _, e in ipairs(list) do teams.on_command_completed(state, e.unit_number, success()) end
    c.by_id[recruit.unit_number] = recruit
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop.pending[recruit.unit_number], 'recruit not in the next hop')
  end)

  test('scout teams: a soldier that left the roster never stalls a hop', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local first = state.teams[1].hop
    c.by_id[list[3].unit_number] = nil
    teams.on_command_completed(state, list[1].unit_number, success())
    teams.on_command_completed(state, list[2].unit_number, success())
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop ~= first, 'a departed member held the hop')
    assert(not state.team_of[list[3].unit_number] and #state.teams[1].members == 2, 'departed member kept')
  end)

  test('scout teams: completions from unknown soldiers or teamless states are ignored', function()
    teams.on_command_completed({}, 12345, success())
    local list = squad({'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    teams.on_command_completed(state, 99999, fail())
  end)

  local function scouting(kinds)
    local list = squad(kinds)
    divisions.assign(1, 1, list)
    assert(scout.set(1, 1, true), 'scout mode did not start')
    return list
  end
  local function scout_state() return divisions.record(1, 1).scout end

  test('scout wiring: a mixed division forms teams on its first sweep and each hops in its sector', function()
    scouting({'carrier', 'carrier', 'carrier', 'carrier', 'flame', 'siege'})
    scout.tick()
    local state = scout_state()
    assert(state.team_count == 2 and state.surface_index == 1, 'teams not formed')
    for id = 1, 2 do
      local team = state.teams[id]
      assert(team.target and team.hop, 'team ' .. id .. ' has no hop')
      local centre = {x = team.target.x * 32 + 16, y = team.target.y * 32 + 16}
      assert(geometry.in_sectors(team.sectors, geometry.angle(state.origin, centre)), 'team ' .. id .. ' left its sector')
    end
  end)

  test('scout wiring: the chunk search spends at most the division budget per sweep', function()
    local kinds = {}
    for i = 1, 12 do kinds[i] = 'carrier' end
    scouting(kinds)
    local force = game.players[1].force
    force.chart(nil, {{x = -20 * 32, y = -20 * 32}, {x = 20 * 32 + 31, y = 20 * 32 + 31}})
    local calls, real = 0, force.is_chunk_charted
    force.is_chunk_charted = function(s, chunk) calls = calls + 1; return real(s, chunk) end
    scout.tick()
    assert(scout_state().team_count == 4, 'expected 4 teams')
    assert(calls <= scout.CHUNK_BUDGET, 'the search asked ' .. calls .. ' chunks in one sweep')
    assert(calls > 0, 'no team searched')
  end)

  test('scout wiring: a recruit joins the smallest team', function()
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    local victim = state.teams[1].members[1]
    for _, e in ipairs(list) do if e.unit_number == victim then e.valid = false end end
    divisions.forget(victim)
    scout.tick()
    local recruit = tank('carrier', 0, 0)
    divisions.add_member(1, 1, recruit.unit_number, recruit)
    assert(scout.join(divisions.record(1, 1), recruit), 'scout refused the recruit')
    assert(state.team_of[recruit.unit_number] == 1, 'recruit did not join the smaller team')
  end)

  test('scout wiring: a player assignment re-forms the teams', function()
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    assert(scout_state().team_count == 2)
    for _ = 1, 3 do list[#list + 1] = tank('carrier', 0, 0) end
    divisions.assign(1, 1, list)
    assert(scout_state().teams == nil, 'assignment kept the old teams')
    scout.tick()
    assert(scout_state().team_count == 3, 'teams not re-formed for 9 soldiers')
  end)

  test('scout wiring: a save from before teams forms teams on its first sweep', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    divisions.assign(1, 1, list)
    local record = divisions.record(1, 1)
    record.mode, record.scout = 'scout', {ring = 3, offset = 5, target = {x = 4, y = 0}, surface_index = 1}
    scout.tick()
    local state = record.scout
    assert(state.teams and state.team_count == 1 and state.ring == nil and state.offset == nil, 'old state not migrated')
    assert(scout.on_command_completed(list[1].unit_number, defines.behavior_result.success))
  end)

  test('scout wiring: members on another surface get no team and no command', function()
    local a, b = tank('carrier', 0, 0), soldier(nil, {index = 2}, 10000, 10000)
    divisions.assign(1, 1, {a, b})
    scout.set(1, 1, true)
    scout.tick()
    local state = scout_state()
    assert(state.team_of[a.unit_number] and not state.team_of[b.unit_number], 'other-surface soldier got a team')
    assert(b.command == nil, 'other-surface soldier got a command')
  end)

  test('scout wiring: every team blocked ends scouting with the exhausted message', function()
    local printed
    game.get_player(1).print = function(message) printed = message end
    scouting({'carrier', 'carrier', 'carrier'})
    scout.tick()
    scout_state().teams[1].blocked = true
    scout.tick()
    assert(divisions.record(1, 1).mode == 'idle' and divisions.record(1, 1).scout == nil, 'blocked division kept scouting')
    assert(printed and printed[1] == 'tank-squads.scout-exhausted', 'no exhausted message')
  end)

  local function kill(e)
    e.valid = false
    divisions.forget(e.unit_number)
  end
  local function in_team(state, id, e) return state.team_of[e.unit_number] == id end

  test('scout merges: a team down to one soldier joins the nearest team and hands over its sector', function()
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    local lone
    for _, e in ipairs(list) do
      if in_team(state, 2, e) then
        if lone then kill(e) else lone = e end
      end
    end
    scout.tick()
    assert(state.teams[2] == nil and in_team(state, 1, lone), 'team 2 did not merge into team 1')
    assert(#state.teams[1].sectors == 2, 'the merged sector was not handed over')
    assert(lone.command.destination.x == state.teams[1].hop.point.x, 'the survivor was not sent to its new team')
    assert(not state.teams[1].hop.pending[lone.unit_number], 'the survivor stalls the host hop')
  end)

  test('scout merges: a team that lost every front soldier joins another team', function()
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'siege', 'siege', 'siege', 'siege'})
    scout.tick()
    local state = scout_state()
    for _, e in ipairs(list) do
      if in_team(state, 2, e) and e.name ~= 'tank-squad-siege' then kill(e) end
    end
    scout.tick()
    assert(state.teams[2] == nil, 'a siege-only team kept scouting alone')
    local sieges = 0
    for _, e in ipairs(list) do if e.valid and e.name == 'tank-squad-siege' and in_team(state, 1, e) then sieges = sieges + 1 end end
    assert(sieges == 4 and #state.teams[1].sectors == 2, 'sieges or sector not handed over')
  end)

  test('scout merges: without a host, a siege-only team leads with its sieges', function()
    local list = scouting({'carrier', 'siege', 'siege', 'siege'})
    scout.tick()
    local state = scout_state()
    assert(state.team_count == 1)
    kill(list[1])
    for i = 2, 4 do scout.on_command_completed(list[i].unit_number, defines.behavior_result.success) end
    scout.tick()
    local hop = state.teams[1].hop
    assert(hop and hop.front[list[2].unit_number], 'sieges not in the front band')
    for i = 2, 4 do assert(math.abs(forward(hop, list[i])) < 1e-6, 'siege trails an empty front') end
  end)

  test('scout merges: a blocked team joins another team and drops its sector', function()
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    state.teams[2].blocked = true
    scout.tick()
    assert(state.teams[2] == nil and #state.teams[1].members == 6, 'blocked team did not merge')
    assert(#state.teams[1].sectors == 1, 'a blocked sector was handed over')
    assert(divisions.record(1, 1).mode == 'scout', 'division stopped while a team could still explore')
  end)

  test('scout merges: a soldier moved to another division mid-hop does not stall its team', function()
    local list = scouting({'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    local first = state.teams[1].hop
    divisions.assign(1, 2, {list[3]})
    scout.on_command_completed(list[1].unit_number, defines.behavior_result.success)
    scout.on_command_completed(list[2].unit_number, defines.behavior_result.success)
    scout.tick()
    assert(state.teams[1].hop ~= first, 'the transferred soldier held the hop')
    assert(not state.team_of[list[3].unit_number], 'the transferred soldier kept its team')
  end)

  test('scout merges: convoys of a merged team move to the host', function()
    building().position = {x = 100, y = 0}
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    local injured, others = nil, {}
    for _, e in ipairs(list) do
      if in_team(state, 2, e) then
        if injured then others[#others + 1] = e else injured = e end
      end
    end
    injured.health = 60
    kill(others[1])
    kill(others[2])
    scout.tick()
    assert(state.teams[2] == nil, 'team with one living soldier did not merge')
    assert(retreat.is_away(state.teams[1], injured.unit_number), 'the injured soldier lost its convoy in the merge')
  end)

  local function depot(x, y)
    local b = building()
    b.position = {x = x, y = y}
    return b
  end

  test('scout healing: a badly hurt team withdraws together, heals and scouts again', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier'})
    for _, e in ipairs(list) do e.health = 150 end -- 37.5 %: no convoy, team below half
    scout.tick()
    local team = scout_state().teams[1]
    assert(team.withdraw and not team.hop, 'team did not withdraw')
    for _, e in ipairs(list) do
      assert(e.command.destination.x == 100 and e.command.radius == retreat.ARRIVAL_RADIUS, 'soldier not sent to the barracks')
    end
    scout.tick()
    assert(team.withdraw, 'withdraw ended before healing')
    for _, e in ipairs(list) do e.health = 400 end
    scout.tick()
    assert(not team.withdraw and team.formed == 3, 'healed team did not resume')
    scout.tick()
    assert(team.hop, 'resumed team did not hop')
  end)

  test('scout healing: a team withdraws to a nearer headquarters and follows it', function()
    depot(300, 0)
    local hq = soldier(nil, nil, 100, 0)
    hq.name = 'tank-squad-headquarters'
    storage.headquarters = {[hq.unit_number] = {entity = hq, force_index = hq.force_index, helpers = {}}}
    local list = scouting({'carrier', 'carrier', 'carrier'})
    for _, e in ipairs(list) do e.health = 150 end
    scout.tick()
    local team = scout_state().teams[1]
    assert(team.withdraw, 'team did not withdraw')
    for _, e in ipairs(list) do
      assert(e.command.destination.x == 100 and e.command.radius == retreat.HQ_ARRIVAL_RADIUS,
        'soldier not sent to the headquarters')
      e.command = nil
    end
    hq.position = {x = 140, y = 0}
    scout.tick()
    for _, e in ipairs(list) do
      assert(e.command and e.command.destination.x == 140, 'team did not follow the headquarters')
    end
    for _, e in ipairs(list) do e.position, e.command = {x = 140 - retreat.HQ_HEAL_RADIUS + 2, y = 0}, nil end
    game.tick = game.tick + retreat.TIMEOUT
    scout.tick()
    game.tick = game.tick + retreat.TIMEOUT
    scout.tick()
    assert(team.withdraw, 'a team healing at the headquarters gave up')
  end)

  test('scout healing: losing half the team triggers a withdraw', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    kill(list[1])
    kill(list[2])
    scout.tick()
    assert(scout_state().teams[1].withdraw, 'half the team lost did not withdraw')
  end)

  test('scout healing: with no barracks in range the team fights on and checks again later', function()
    local list = scouting({'carrier', 'carrier', 'carrier'})
    for _, e in ipairs(list) do e.health = 150 end
    scout.tick()
    local team = scout_state().teams[1]
    assert(not team.withdraw and team.hop, 'team withdrew without a barracks')
    assert(team.withdraw_after == game.tick + geometry.NO_BARRACKS_RETRY, 'no retry delay')
  end)

  test('scout healing: a stuck withdraw ends after the timeout and waits before the next', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier'})
    for _, e in ipairs(list) do e.health = 150 end
    scout.tick()
    local team = scout_state().teams[1]
    assert(team.withdraw, 'team did not withdraw')
    scout.tick() -- records the closest distance so far; nobody moves after this
    game.tick = game.tick + retreat.TIMEOUT
    scout.tick()
    assert(not team.withdraw and team.withdraw_after == game.tick + retreat.TIMEOUT, 'stuck withdraw kept going')
    scout.tick()
    assert(not team.withdraw and team.hop, 'withdrew again during the cooldown')
  end)

  test('scout healing: a destroyed barracks with none left ends the withdraw', function()
    local b = depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier'})
    for _, e in ipairs(list) do e.health = 150 end
    scout.tick()
    local team = scout_state().teams[1]
    assert(team.withdraw)
    b.valid = false
    scout.tick()
    assert(not team.withdraw and team.withdraw_after, 'withdraw kept a destroyed barracks')
    scout.tick()
    assert(team.hop, 'team did not go back to scouting')
  end)

  test('scout healing: a soldier pushed away during a withdraw is sent back after its completion', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier'})
    for _, e in ipairs(list) do e.health = 150 end
    scout.tick()
    list[1].position, list[1].command = {x = 150, y = 0}, nil
    scout.tick()
    assert(list[1].command == nil, 'resent while it may still be walking')
    scout.on_command_completed(list[1].unit_number, defines.behavior_result.success)
    scout.tick()
    assert(list[1].command and list[1].command.destination.x == 100, 'displaced soldier not sent back')
  end)

  test('scout healing: one hurt soldier leaves in a convoy without stalling the hop', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier'})
    scout.tick()
    local team = scout_state().teams[1]
    local first = team.hop
    list[3].health = 100
    scout.tick()
    assert(retreat.is_away(team, list[3].unit_number) and not team.withdraw, 'wrong retreat')
    assert(not first.pending[list[3].unit_number], 'convoy soldier still pending')
    scout.on_command_completed(list[1].unit_number, defines.behavior_result.success)
    scout.on_command_completed(list[2].unit_number, defines.behavior_result.success)
    scout.tick()
    assert(team.hop ~= first and not team.hop.pending[list[3].unit_number], 'hop waited for the convoy')
  end)

  test('scout healing: a team with every member away waits, then resumes when they heal', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier'})
    scout.tick()
    local team = scout_state().teams[1]
    for _, e in ipairs(list) do e.health = 100 end
    scout.tick()
    assert(retreat.is_away(team, list[1].unit_number) and retreat.is_away(team, list[2].unit_number))
    local orders = {list[1].command, list[2].command}
    scout.tick()
    assert(list[1].command == orders[1] and list[2].command == orders[2], 'away soldiers re-commanded')
    assert(scout_state().teams[1] == team, 'empty team merged into nothing')
    for _, e in ipairs(list) do e.health = 400 end
    scout.tick()
    assert(team.hop and team.hop.pending[list[1].unit_number], 'team did not resume after healing')
  end)

  test('scout healing: scouting switched off and on mid-convoy starts clean', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier'})
    scout.tick()
    list[3].health = 100
    scout.tick()
    scout.set(1, 1, false)
    scout.set(1, 1, true)
    assert(scout.on_command_completed(list[3].unit_number, defines.behavior_result.success))
    scout.tick()
    assert(scout_state().team_of[list[3].unit_number], 'fresh teams left out the returning soldier')
  end)

  test('scout review: a blocked team with no host left does not crash the sweep', function()
    game.get_player(1).print = function() end
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    local one, two = state.teams[1], state.teams[2]
    two.blocked, two.hop, two.target, two.march = true, nil, nil, 6
    one.target, one.found, one.march, one.failures = nil, nil, 5, 4
    for _, e in ipairs(list) do
      if in_team(state, 1, e) then scout.on_command_completed(e.unit_number, defines.behavior_result.fail) end
    end
    scout.tick()
    assert(divisions.record(1, 1).mode == 'idle', 'every team blocked but the division kept scouting')
  end)

  test('scout review: soldiers away healing do not merge their team away', function()
    depot(100, 0)
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    local hurt, team_two = 0, {}
    for _, e in ipairs(list) do
      if in_team(state, 2, e) then
        team_two[#team_two + 1] = e
        if hurt < 2 then e.health, hurt = 100, hurt + 1 end
      end
    end
    scout.tick()
    assert(state.teams[2], 'a team merged away while two of its soldiers were healing')
    scout.tick()
    assert(state.teams[2], 'the team merged on a later sweep')
    for _, e in ipairs(team_two) do e.health = 400 end
    scout.tick()
    local team = state.teams[2]
    assert(team and team.hop, 'team did not resume')
    for unit in pairs(team.hop.pending) do scout.on_command_completed(unit, defines.behavior_result.success) end
    scout.tick()
    for _, e in ipairs(team_two) do assert(team.hop.pending[e.unit_number], 'a healed soldier is missing from the hop') end
  end)

  test('scout review: a team whose every nearby chunk is unreachable marches instead of retrying forever', function()
    local list = scouting({'carrier', 'carrier', 'carrier'})
    scout.tick()
    local team = scout_state().teams[1]
    for _ = 1, geometry.MARCH_ANGLES do
      assert(team.target, 'lost the chunk target early')
      for _, e in ipairs(list) do scout.on_command_completed(e.unit_number, defines.behavior_result.fail) end
      scout.tick()
    end
    assert(team.march and not team.target and team.hop, 'team kept targeting unreachable chunks')
    assert(not team.blocked, 'blocked before any march angle was tried')
  end)

  test('scout review: only failed march hops in a row block a team', function()
    game.get_player(1).print = function() end
    local list = scouting({'carrier', 'carrier', 'carrier'})
    local force = game.players[1].force
    force.chart(nil, {{x = -40 * 32, y = -40 * 32}, {x = 40 * 32 + 31, y = 40 * 32 + 31}})
    local team
    for _ = 1, 200 do
      scout.tick()
      team = scout_state().teams[1]
      if team.march then break end
    end
    assert(team.march and team.hop, 'team never started marching')
    local function hop(result)
      for _, e in ipairs(list) do scout.on_command_completed(e.unit_number, result) end
      scout.tick()
    end
    for _ = 1, geometry.MARCH_ANGLES - 1 do hop(defines.behavior_result.fail) end
    local angle = team.march
    hop(defines.behavior_result.success)
    assert(team.march == angle, 'a successful march hop changed the angle')
    for _ = 1, geometry.MARCH_ANGLES - 1 do hop(defines.behavior_result.fail) end
    assert(not team.blocked, 'failures separated by a successful hop blocked the team')
    hop(defines.behavior_result.fail)
    assert(team.blocked or divisions.record(1, 1).mode == 'idle', 'five failed march hops in a row did not block the team')
  end)

  -- Valid map labels (plain chart text) by text, and the insignia map badges.
  local function labels()
    local out, badges = {}, 0
    for _, d in ipairs(ctx.draws()) do
      if d.valid and d.args.render_mode == 'chart' and d.args.text then
        if d.args.use_rich_text then badges = badges + 1 else out[d.args.text] = (out[d.args.text] or 0) + 1 end
      end
    end
    return out, badges
  end

  test('scout labels: each team shows on the map in place of the division label', function()
    scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    divisions.refresh()
    assert(labels()['1'] == 1, 'no division label before the teams form')
    scout.tick()
    local found, badges = labels()
    assert(found['1A'] == 1 and found['1B'] == 1, 'team labels missing')
    assert(not found['1'], 'division label kept beside the team labels')
    assert(badges == 2, 'expected one map insignia per team, got ' .. badges)
    local count = #ctx.draws()
    divisions.refresh()
    scout.tick()
    assert(#ctx.draws() == count, 'unchanged team labels redrawn')
  end)

  test('scout labels: a merged team loses its label', function()
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    local state = scout_state()
    local lone
    for _, e in ipairs(list) do
      if in_team(state, 2, e) then
        if lone then kill(e) else lone = e end
      end
    end
    scout.tick()
    assert(state.teams[2] == nil, 'team 2 did not merge')
    local found, badges = labels()
    assert(found['1A'] == 1 and not found['1B'] and badges == 1, 'merged team kept its label')
  end)

  test('scout labels: stopping the scout brings back the division label at once', function()
    scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    scout.set(1, 1, false)
    local found, badges = labels()
    assert(found['1'] == 1 and not found['1A'] and not found['1B'] and badges == 1, 'team labels outlived the scout')
  end)

  test('scout labels: an order or an exhausted scout drops the team labels', function()
    game.get_player(1).print = function() end
    scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    scout.tick()
    for id = 1, 2 do scout_state().teams[id].blocked = true end
    scout.tick()
    local found = labels()
    assert(divisions.record(1, 1).mode == 'idle' and found['1'] == 1 and not found['1A'], 'exhausted scout kept team labels')
    scout.set(1, 1, true)
    scout.tick()
    assert(labels()['1A'] == 1, 'teams formed again without labels')
    divisions.record(1, 1).mode, divisions.record(1, 1).scout = 'idle', nil
    divisions.refresh()
    found = labels()
    assert(found['1'] == 1 and not found['1A'] and not found['1B'], 'a scout ended elsewhere kept team labels')
    divisions.clear_player(1)
    for _, d in ipairs(ctx.draws()) do assert(not d.valid, 'cleared division leaked a label') end
  end)

  -- Soldiers step onto their destinations and report arrival.
  local function arrive(state, list)
    for _, e in ipairs(list) do
      if e.command then
        e.position = {x = e.command.destination.x, y = e.command.destination.y}
        teams.on_command_completed(state, e.unit_number, success())
      end
    end
  end
  local function water(fn) game.surfaces[1].wet = fn end

  test('scout water: a hop point in narrow water moves to the far bank on the same line', function()
    water(function(x) return x > 30 and x < 50 end)
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    teams.sweep(state, 1, context(list, {x = 20, y = 0}))
    local team = state.teams[1]
    assert(team.hop and team.hop.point.x >= 50 and team.hop.point.x <= 36 + geometry.WADE, 'hop not on the far bank')
    assert(not team.detours and team.target.x == 20, 'wading counted as a shore hop')
    water(nil)
  end)

  -- Water between the team and its target chunk 20:0, which is dry land.
  local function lake(x) return x > 20 and x < 600 end

  test('scout water: open water ahead turns the hop along the shore and keeps the target', function()
    water(lake)
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    teams.sweep(state, 1, context(list, {x = 20, y = 0}))
    local team = state.teams[1]
    assert(team.hop and team.hop.point.x <= 20, 'hop point on water')
    assert(team.detours == 1 and team.side == 1 and team.target.x == 20, 'shore hop not recorded')
    for _, e in ipairs(list) do assert(e.command.destination.x <= 20 + geometry.SPACING * 2, 'soldier sent into the water') end
    water(nil)
  end)

  test('scout water: with no dry point the target is given up at once, with no orders', function()
    water(function(x) return x < 600 end)
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    teams.sweep(state, 1, context(list, {x = 20, y = 0}))
    local team = state.teams[1]
    assert(not team.hop and not team.target, 'a wet hop started')
    assert(team.failed['20:0'] == game.tick + geometry.WATER_TTL, 'wet target not blocked for WATER_TTL')
    for _, e in ipairs(list) do assert(e.command == nil, 'soldier ordered into the water') end
    water(nil)
  end)

  test('scout water: a target still across the water after DETOUR_LIMIT shore hops is given up', function()
    water(lake)
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    local team = state.teams[1]
    for _ = 1, geometry.DETOUR_LIMIT + 2 do
      teams.sweep(state, 1, c)
      if team.failed and team.failed['20:0'] then break end
      arrive(state, list)
    end
    assert(team.failed and team.failed['20:0'], 'target across the water never given up')
    water(nil)
  end)

  test('scout stragglers: a soldier far from the team walks after it and never holds a hop', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local far = tank('carrier', 500, 0)
    list[4] = far
    local state = {surface_index = 1}
    teams.form(state, list)
    state.teams[1].last_point = {x = 4, y = 0}
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local hop = state.teams[1].hop
    assert(not hop.pending[far.unit_number], 'straggler holds the hop')
    assert(far.command.destination.x == hop.point.x and far.command.radius == 8, 'straggler not sent after the team')
    local order = far.command
    arrive(state, {list[1], list[2], list[3]})
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop ~= hop, 'hop waited for the straggler')
    assert(far.command == order, 'straggler order renewed before it completed')
    teams.on_command_completed(state, far.unit_number, success())
    arrive(state, {list[1], list[2], list[3]})
    teams.sweep(state, 1, c)
    assert(far.command ~= order and far.command.destination.x == state.teams[1].hop.point.x, 'straggler not sent again')
  end)

  test('scout stragglers: a team far from its last hop point gathers on its nearest soldier', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    state.teams[1].last_point = {x = 1000, y = 0}
    teams.sweep(state, 1, context(list, {x = 20, y = 0}))
    local hop = state.teams[1].hop
    assert(hop and hop.from.x == 6 and hop.from.y == 0, 'hop did not start from the nearest soldier')
    for _, e in ipairs(list) do assert(hop.pending[e.unit_number], 'soldier left out of the hop') end
  end)

  test('scout grace: once the front arrives, the rest get GRACE ticks', function()
    local list = squad({'carrier', 'carrier', 'siege'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local hop = state.teams[1].hop
    arrive(state, {list[1], list[2]})
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop == hop and hop.expires == game.tick + geometry.GRACE, 'no grace for the rear')
    game.tick = game.tick + geometry.GRACE
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop ~= hop, 'hop outlived the grace')
  end)

  test('scout stall: a team that hops STALL_HOPS times without charting a target is blocked', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local team = state.teams[1]
    assert(team.idle == 1, 'hop not counted')
    game.players[1].force.chart(nil, {{x = 20 * 32, y = 0}, {x = 20 * 32 + 1, y = 1}})
    arrive(state, list)
    teams.sweep(state, 1, c)
    assert(team.idle == 1, 'charting the target did not reset the count')
    arrive(state, list)
    team.target, team.idle = {x = 40, y = 0}, geometry.STALL_HOPS
    teams.sweep(state, 1, c)
    assert(team.blocked and not team.hop, 'stalled team kept hopping')
  end)

  test('scout stall: a target not charted after TARGET_HOPS hops is given up', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 60, y = 0})
    local team = state.teams[1]
    for _ = 1, geometry.TARGET_HOPS do
      teams.sweep(state, 1, c)
      assert(team.hop and not (team.failed and team.failed['60:0']), 'target given up early')
      arrive(state, list)
    end
    teams.sweep(state, 1, c)
    assert(team.failed and team.failed['60:0'] and not team.hop, 'target kept after TARGET_HOPS hops')
    c.search = function() return {x = 0, y = 30} end
    teams.sweep(state, 1, c)
    assert(team.target.y == 30 and team.target_hops == 1 and team.hop, 'next target did not start a fresh count')
  end)

  test('scout grace: a front tank stuck short of its slot holds the team only for GRACE', function()
    local list = squad({'flame', 'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local hop = state.teams[1].hop
    assert(hop.front[list[1].unit_number], 'flame tank not leading')
    arrive(state, {list[2]})
    teams.sweep(state, 1, c)
    assert(hop.expires == geometry.HOP_TIMEOUT, 'grace before half the team arrived')
    arrive(state, {list[3]})
    teams.sweep(state, 1, c)
    assert(state.teams[1].hop == hop and hop.expires == game.tick + geometry.GRACE, 'no grace with half the team there')
  end)

  test('scout sea: an open-water target is skipped by the whole division without a failure', function()
    water(function(x) return x >= 640 end)
    local list = scouting({'carrier', 'carrier', 'carrier', 'carrier', 'carrier', 'carrier'})
    local state = scout_state()
    scout.tick()
    local team = state.teams[1]
    local sea_target = {x = 20, y = 0}
    team.target, team.probe, team.hop = sea_target, nil, nil
    scout.tick()
    assert(team.target ~= sea_target and not team.failures, 'sea target kept or counted as a failure')
    assert(state.sea[geometry.chunk_key(20, 0)] == game.tick + geometry.SEA_TTL, 'sea chunk not remembered')
    game.players[1].force.chart(nil, {{x = -30 * 32, y = -30 * 32}, {x = 19 * 32 + 31, y = 30 * 32 + 31}})
    for _ = 1, 20 do
      team.target, team.march, team.hop, team.ring, team.offset, team.search_centre = nil, nil, nil, nil, nil, nil
      scout.tick()
      if team.target then
        assert(team.target.x ~= 20 or team.target.y ~= 0, 'the search picked a remembered sea chunk')
      end
    end
    water(nil)
  end)

  test('scout sea: an ungenerated target is generated and checked on a later sweep', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local surface, asked = game.surfaces[1], nil
    surface.is_chunk_generated = function() return false end
    surface.request_to_generate_chunks = function(position) asked = position end
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    local team = state.teams[1]
    assert(asked and asked.x == 20 * 32 + 16 and team.probe == 'asked' and team.hop, 'target not generated')
    surface.is_chunk_generated = function() return true end
    water(function(x) return x >= 640 end)
    arrive(state, list)
    teams.sweep(state, 1, c)
    assert(state.sea and state.sea[geometry.chunk_key(20, 0)], 'generated sea target not remembered')
    water(nil)
  end)

  test('scout water: the far bank search stops at ungenerated ground', function()
    local surface = game.surfaces[1]
    -- Chunks east of x = 64 are not generated; water covers x 30 to 64.
    surface.is_chunk_generated = function(chunk) return chunk.x < 2 end
    water(function(x) return x > 30 and x < 64 end)
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    teams.sweep(state, 1, context(list, {x = 20, y = 0}))
    local team = state.teams[1]
    assert(team.hop and team.hop.point.x < 64, 'hop sent onto ungenerated ground past the water')
    surface.is_chunk_generated = function() return true end
    water(nil)
  end)

  -- Two teams of three carriers (three with count 9), each on its first hop
  -- towards chunk 20:0. Returns the soldiers, the state and the context.
  local function pair(count)
    local kinds = {}
    for i = 1, count or 6 do kinds[i] = 'carrier' end
    local list = squad(kinds)
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    for id = 1, state.team_count do teams.sweep(state, id, c) end
    return list, state, c
  end
  local function of(state, id, list)
    local out = {}
    for _, e in ipairs(list) do if state.team_of[e.unit_number] == id then out[#out + 1] = e end end
    return out
  end
  local function wound(soldiers, health)
    for _, e in ipairs(soldiers) do e.health = health end
  end

  test('scout aid: a first sweep records the peak and opens no call, even when hurt', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    wound(list, 300)
    local state = {surface_index = 1}
    teams.form(state, list)
    teams.sweep(state, 1, context(list, {x = 20, y = 0}))
    local team = state.teams[1]
    assert(team.peak and team.peak.ratio == 0.75 and team.ratio == 0.75, 'peak or ratio not recorded')
    assert(not team.call and team.hop, 'a team hurt before scouting called for help')
  end)

  test('scout aid: a team losing 15 points falls back to where its hop started, facing the advance', function()
    local list, state, c = pair()
    local team = state.teams[1]
    local hop, idle, hops = team.hop, team.idle, team.target_hops
    local mine = of(state, 1, list)
    wound(mine, 340)
    teams.sweep(state, 1, c)
    local call = team.call
    assert(call and call.point.x == 6 and call.point.y == 0, 'no call at the start of the hop')
    assert(team.hop ~= hop and team.hop.fallback and team.last_point.x == 6, 'no fall-back hop')
    assert(team.hop.heading.x > 0.99, 'the fall-back does not face the advance')
    assert(not team.failures and team.idle == idle and team.target_hops == hops, 'the fall-back counted as a hop')
    for _, e in ipairs(mine) do
      assert(team.hop.pending[e.unit_number], 'a soldier did not fall back')
      assert(math.abs(forward(team.hop, e)) < 1e-6, 'a soldier is not on its front slot')
    end
  end)

  test('scout aid: a caller with no ground behind it stops where its soldiers stand', function()
    for _, back in ipairs({'none', 'far'}) do
      local list, state, c = pair()
      local team = state.teams[1]
      team.back = back == 'far' and {point = {x = 500, y = 0}, heading = {x = 1, y = 0}} or nil
      local mine = of(state, 1, list)
      wound(mine, 300)
      teams.sweep(state, 1, c)
      assert(team.call and team.call.point.x == 6 and team.call.point.y == 0, back .. ': the call is not where the soldiers stand')
      assert(team.hop.fallback and team.last_point.x == 6, back .. ': the hop in progress went on into the fight')
      for _, e in ipairs(mine) do teams.on_command_completed(state, e.unit_number, fail()) end
      teams.sweep(state, 1, c)
      assert(not team.failures and team.target and team.target.x == 20, back .. ': stopping counted as a scouting failure')
    end
  end)

  test('scout aid: a team that takes in a merged soldier starts a fresh peak and does not call', function()
    local list, state, c = pair()
    local mine = of(state, 1, list)
    mine[1].health = 160
    c.by_id[mine[2].unit_number], c.by_id[mine[3].unit_number] = nil, nil
    teams.sweep(state, 1, c)
    assert(state.teams[1] == nil, 'the lone soldier did not merge')
    teams.sweep(state, 2, c)
    assert(not state.teams[2].call, 'the host read its newcomer as a fight')
  end)

  test('scout aid: a soldier killed opens a call', function()
    local list, state, c = pair()
    local victim = of(state, 1, list)[1]
    victim.valid = false
    c.by_id[victim.unit_number] = nil
    teams.sweep(state, 1, c)
    assert(state.teams[1].call, 'a death did not open a call')
  end)

  test('scout aid: a soldier moved to another division is no death', function()
    local list, state, c = pair()
    c.by_id[of(state, 1, list)[1].unit_number] = nil
    teams.sweep(state, 1, c)
    assert(not state.teams[1].call, 'a transfer opened a call')
  end)

  test('scout aid: a caller holds after falling back, then goes around its old target after QUIET', function()
    local list, state, c = pair()
    local team = state.teams[1]
    local mine = of(state, 1, list)
    wound(mine, 340)
    teams.sweep(state, 1, c)
    local point = team.call.point
    game.tick = 120
    wound(mine, 280)
    teams.sweep(state, 1, c)
    assert(team.call.point == point and team.call.last_drop == 120, 'a new drop moved the call or did not refresh it')
    arrive(state, mine)
    teams.sweep(state, 1, c)
    assert(team.call and not team.hop, 'the caller did not hold after falling back')
    game.tick = 120 + geometry.QUIET - 1
    teams.sweep(state, 1, c)
    assert(team.call and not team.hop, 'the call ended before QUIET')
    game.tick = 120 + geometry.QUIET
    c.search = function() return {x = 0, y = 20} end
    teams.sweep(state, 1, c)
    assert(not team.call, 'the call outlived QUIET')
    assert(team.failed['20:0'] == game.tick + geometry.DANGER_TTL, 'the old target was not given up')
    assert(team.target.x == 0 and team.target.y == 20, 'the team did not look for other fog')
    assert(team.hop and not team.hop.fallback and not team.failures, 'the team did not go back to scouting')
  end)

  test('scout aid: a marching caller turns to its next march angle after its call', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, nil, true)
    teams.sweep(state, 1, c)
    local team = state.teams[1]
    assert(team.march == 1 and team.hop, 'the team did not march')
    wound(list, 300)
    teams.sweep(state, 1, c)
    assert(team.call and team.hop.fallback, 'the marching team did not fall back')
    game.tick = geometry.QUIET
    teams.sweep(state, 1, c)
    assert(not team.call and team.march == 2 and not team.failures, 'the march did not turn')
  end)

  test('scout aid: a caller that withdraws ends its call, gives up its target and heals with a fresh peak', function()
    depot(100, 0)
    local list, state, c = pair()
    local team = state.teams[1]
    local mine = of(state, 1, list)
    wound(mine, 300)
    teams.sweep(state, 1, c)
    assert(team.call, 'no call')
    wound(mine, 150)
    teams.sweep(state, 1, c)
    assert(team.withdraw and not team.call, 'the withdraw kept the call')
    assert(team.failed and team.failed['20:0'], 'the withdraw kept the target')
    wound(mine, 400)
    teams.sweep(state, 1, c)
    assert(not team.withdraw and team.peak == nil, 'a healed team kept its old peak')
  end)

  test('scout aid: a call ends after QUIET even while every soldier is away healing', function()
    depot(100, 0)
    local list, state, c = pair()
    local team = state.teams[1]
    local mine = of(state, 1, list)
    wound(mine, 300)
    teams.sweep(state, 1, c)
    wound(mine, 100)
    teams.sweep(state, 1, c)
    for _, e in ipairs(mine) do assert(retreat.is_away(team, e.unit_number), 'a soldier did not leave to heal') end
    assert(team.call, 'the call ended when the soldiers left')
    game.tick = geometry.QUIET
    teams.sweep(state, 1, c)
    assert(not team.call and team.failed['20:0'], 'the call outlived QUIET while its soldiers were away')
  end)

  test('scout aid: a blocked caller with no team to join ends its call', function()
    local list = squad({'carrier', 'carrier', 'carrier'})
    local state = {surface_index = 1}
    teams.form(state, list)
    local c = context(list, {x = 20, y = 0})
    teams.sweep(state, 1, c)
    wound(list, 300)
    teams.sweep(state, 1, c)
    local team = state.teams[1]
    assert(team.call, 'no call')
    team.blocked = true
    teams.sweep(state, 1, c)
    assert(not team.call, 'a blocked team kept calling')
  end)

  test('scout aid: the nearest healthy team answers the call', function()
    local list, state, c = pair(9)
    wound(of(state, 1, list), 300)
    state.teams[2].last_point = {x = 100, y = 0}
    teams.sweep(state, 1, c)
    local call = state.teams[1].call
    assert(call.helper == 3 and state.teams[3].helping == 1 and state.teams[3].help_hops == 0, 'the nearest team did not answer')
    assert(not state.teams[2].helping, 'a second team answered')
  end)

  test('scout aid: of two teams equally near, the lower id answers', function()
    local list, state, c = pair(9)
    wound(of(state, 1, list), 300)
    state.teams[2].last_point, state.teams[3].last_point = {x = 50, y = 0}, {x = 50, y = 0}
    teams.sweep(state, 1, c)
    assert(state.teams[1].call.helper == 2, 'the tie did not go to the lower id')
  end)

  test('scout aid: blocked, withdrawing, calling, helping, lone, hurt, fresh and distant teams do not answer', function()
    local cases = {
      blocked = function(t) t.blocked = true end,
      withdrawing = function(t) t.withdraw = {} end,
      calling = function(t) t.call = {point = {x = 0, y = 0}, last_drop = 0} end,
      helping = function(t) t.helping = 3 end,
      lone = function(t) t.members, t.present = {t.members[1]}, 1 end,
      hurt = function(t) t.ratio = geometry.HELPER_HEALTH - 0.01 end,
      fresh = function(t) t.ratio = nil end,
      distant = function(t) t.last_point = {x = 6 + geometry.HELP_RANGE + 1, y = 0} end,
    }
    for name, spoil in pairs(cases) do
      local list, state, c = pair()
      spoil(state.teams[2])
      wound(of(state, 1, list), 300)
      teams.sweep(state, 1, c)
      assert(state.teams[1].call and not state.teams[1].call.helper, 'a ' .. name .. ' team answered')
    end
  end)

  test('scout aid: the helper drops its hop without a failure and heads for the call point', function()
    local list, state, c = pair()
    local helper = state.teams[2]
    local idle, hops, target = helper.idle, helper.target_hops, helper.target
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    local hop = helper.hop
    assert(hop and hop.help and hop.heading.x < -0.99, 'no help hop towards the call point')
    assert(helper.help_hops == 1 and helper.idle == idle and helper.target_hops == hops, 'a help hop counted as a scouting hop')
    assert(not helper.failures and helper.target == target, 'dropping the hop counted as a failure')
    for _, e in ipairs(of(state, 2, list)) do assert(hop.pending[e.unit_number], 'a helper soldier was left out') end
  end)

  test('scout aid: the helper holds once it reaches the call point', function()
    local list, state, c = pair()
    local helper = state.teams[2]
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    local helpers = of(state, 2, list)
    for _ = 1, 3 do
      arrive(state, helpers)
      teams.sweep(state, 2, c)
      if not helper.hop then break end
    end
    local call = state.teams[1].call
    assert(not helper.hop and geometry.distance(helper.last_point, call.point) < 1, 'the helper did not stop at the call point')
    local order = helpers[1].command
    teams.sweep(state, 2, c)
    assert(not helper.hop and helpers[1].command == order, 'the helper moved on while the call was open')
  end)

  test('scout aid: a helper gives up after HELP_HOPS and the caller asks the next team', function()
    local list, state, c = pair(9)
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    local call = state.teams[1].call
    assert(call.helper == 2, 'team 2 did not answer')
    state.teams[2].help_hops = geometry.HELP_HOPS
    teams.sweep(state, 2, c)
    local two = state.teams[2]
    assert(not two.helping and call.refused[2] and not call.helper, 'the helper did not give up')
    assert(not (two.failed and next(two.failed)) and not two.failures, 'giving up counted as a scouting failure')
    teams.sweep(state, 1, c)
    assert(call.helper == 3 and state.teams[3].helping == 1, 'the caller asked the refusing team again or nobody')
  end)

  test('scout aid: a help hop whose front failed ends the help without blocking a chunk', function()
    local list, state, c = pair()
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    local helper = state.teams[2]
    assert(helper.hop and helper.hop.help, 'no help hop')
    for _, e in ipairs(of(state, 2, list)) do teams.on_command_completed(state, e.unit_number, fail()) end
    teams.sweep(state, 2, c)
    local call = state.teams[1].call
    assert(not helper.helping and call.refused[2] and not call.helper, 'a failed help hop did not end the help')
    assert(not helper.failures and not (helper.failed and next(helper.failed)), 'a failed help hop counted as a scouting failure')
    assert(helper.hop and not helper.hop.help, 'the helper did not go back to scouting')
  end)

  test('scout aid: a helper with no dry way to the call point gives up', function()
    local list, state, c = pair()
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    water(function() return true end)
    teams.sweep(state, 2, c)
    water(nil)
    local helper, call = state.teams[2], state.teams[1].call
    assert(not helper.helping and call.refused[2] and not helper.hop, 'the helper walked into water')
    assert(not helper.failures and not (helper.failed and next(helper.failed)), 'the water counted as a scouting failure')
  end)

  test('scout aid: a caller that withdraws releases its helper', function()
    depot(100, 0)
    local list, state, c = pair()
    local mine = of(state, 1, list)
    wound(mine, 300)
    teams.sweep(state, 1, c)
    assert(state.teams[2].helping == 1, 'team 2 did not answer')
    wound(mine, 150)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    local two = state.teams[2]
    assert(not two.helping and two.hop and not two.hop.help, 'the helper kept helping a withdrawing team')
  end)

  test('scout aid: a caller that merges away releases its helper', function()
    local list, state, c = pair()
    local mine = of(state, 1, list)
    wound(mine, 300)
    teams.sweep(state, 1, c)
    c.by_id[mine[2].unit_number], c.by_id[mine[3].unit_number] = nil, nil
    teams.sweep(state, 1, c)
    assert(state.teams[1] == nil, 'the caller did not merge')
    teams.sweep(state, 2, c)
    assert(not state.teams[2].helping, 'the helper kept helping a merged team')
  end)

  test('scout aid: a helper that merges away is replaced', function()
    local list, state, c = pair(9)
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    assert(state.teams[1].call.helper == 2, 'team 2 did not answer')
    local theirs = of(state, 2, list)
    c.by_id[theirs[2].unit_number], c.by_id[theirs[3].unit_number] = nil, nil
    teams.sweep(state, 2, c)
    assert(state.teams[2] == nil, 'the helper did not merge')
    teams.sweep(state, 1, c)
    assert(state.teams[1].call.helper == 3 and state.teams[3].helping == 1, 'the caller found no new helper')
  end)

  test('scout aid: a helper that gets hurt falls back, calls itself and stops helping', function()
    local list, state, c = pair()
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    wound(of(state, 2, list), 300)
    teams.sweep(state, 2, c)
    local helper = state.teams[2]
    assert(helper.call and not helper.helping and not state.teams[1].call.helper, 'the hurt helper kept helping')
    assert(helper.hop and helper.hop.fallback, 'the hurt helper did not fall back')
  end)

  test('scout aid: a helper that withdraws stops helping', function()
    depot(100, 0)
    local list, state, c = pair()
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    wound(of(state, 2, list), 150)
    teams.sweep(state, 2, c)
    local helper = state.teams[2]
    assert(helper.withdraw and not helper.helping and not state.teams[1].call.helper, 'the withdrawing helper kept helping')
  end)

  test('scout aid: a released helper keeps its target with a fresh hop count', function()
    local list, state, c = pair()
    local helper = state.teams[2]
    local target = helper.target
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    helper.target_hops = 15
    state.teams[1].call = nil
    arrive(state, of(state, 2, list))
    teams.sweep(state, 2, c)
    assert(not helper.helping and not helper.failures, 'the released helper counted a failure')
    assert(helper.target == target and helper.target_hops == 1, 'the helper lost its target or kept its old hop count')
    assert(helper.hop and not helper.hop.help, 'the helper did not go back to scouting')
  end)

  test('scout aid: two teams hurt at once both fall back, neither helps, and both resume after QUIET', function()
    local list, state, c = pair()
    wound(list, 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    local one, two = state.teams[1], state.teams[2]
    assert(one.call and two.call and one.hop.fallback and two.hop.fallback, 'a hurt team did not fall back')
    assert(not one.call.helper and not two.call.helper and not one.helping and not two.helping, 'a hurt team answered')
    game.tick = geometry.QUIET
    c.search = function() return {x = 0, y = 20} end
    arrive(state, list)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    assert(not one.call and not two.call and one.hop and two.hop, 'the teams did not resume after QUIET')
  end)

  test('scout aid: a helper is released when a caller whose soldiers are all away ends its call', function()
    depot(100, 0)
    local list, state, c = pair()
    local mine = of(state, 1, list)
    wound(mine, 300)
    teams.sweep(state, 1, c)
    assert(state.teams[2].helping == 1, 'team 2 did not answer')
    wound(mine, 100)
    teams.sweep(state, 1, c)
    game.tick = geometry.QUIET
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    assert(not state.teams[1].call and not state.teams[2].helping, 'the helper stayed with a call that went quiet')
  end)

  test('scout aid: a soldier back from healing unhealed is no fight', function()
    depot(100, 0)
    local list, state, c = pair()
    local team = state.teams[1]
    local hurt = of(state, 1, list)[1]
    hurt.health = 100
    teams.sweep(state, 1, c)
    assert(retreat.is_away(team, hurt.unit_number) and not team.call, 'the injured soldier did not leave quietly')
    for _, convoy in pairs(team.retreat.convoys) do convoy.failures = retreat.FAILURE_LIMIT end
    teams.sweep(state, 1, c)
    assert(not retreat.is_away(team, hurt.unit_number), 'the convoy did not give up')
    assert(not team.call, 'an unhealed soldier coming back opened a call')
  end)

  test('scout aid: a team waiting for its soldiers to come back from healing is not asked to help', function()
    depot(100, 0)
    local list, state, c = pair(9)
    local theirs = of(state, 2, list)
    theirs[1].health, theirs[2].health = 100, 100
    teams.sweep(state, 2, c)
    assert(retreat.is_away(state.teams[2], theirs[1].unit_number), 'the soldiers did not leave to heal')
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    assert(state.teams[1].call.helper == 3, 'a team with one soldier at hand was asked to help')
  end)

  test('scout aid: a helper whose soldiers leave to heal is replaced', function()
    depot(100, 0)
    local list, state, c = pair(9)
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    assert(state.teams[1].call.helper == 2, 'team 2 did not answer')
    local theirs = of(state, 2, list)
    theirs[1].health, theirs[2].health = 100, 100
    teams.sweep(state, 2, c)
    teams.sweep(state, 1, c)
    assert(state.teams[1].call.helper == 3 and state.teams[3].helping == 1, 'the caller waited on a helper that cannot come')
  end)

  test('scout aid: a death while the team waits for its healers calls once they are back', function()
    depot(100, 0)
    local list, state, c = pair()
    local team = state.teams[1]
    local mine = of(state, 1, list)
    mine[1].health = 100
    teams.sweep(state, 1, c)
    assert(retreat.is_away(team, mine[1].unit_number), 'the injured soldier did not leave')
    mine[2].valid = false
    c.by_id[mine[2].unit_number] = nil
    teams.sweep(state, 1, c)
    assert(not team.call, 'a lone soldier called')
    mine[1].health = 400
    teams.sweep(state, 1, c)
    assert(team.call, 'the death was forgotten')
  end)

  test('scout aid: a helper whose last hop onto the call point fails still holds there', function()
    local list, state, c = pair()
    local helper = state.teams[2]
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    local helpers = of(state, 2, list)
    arrive(state, helpers)
    teams.sweep(state, 2, c)
    assert(helper.hop and helper.hop.reach, 'no final hop onto the call point')
    for _, e in ipairs(helpers) do teams.on_command_completed(state, e.unit_number, fail()) end
    teams.sweep(state, 2, c)
    local call = state.teams[1].call
    assert(helper.helping == 1 and call.helper == 2 and not call.refused, 'crowding at the call point read as a refusal')
    assert(not helper.hop, 'the helper did not hold')
  end)

  test('scout aid: a helper called away mid-hop heads for the new call', function()
    local list, state, c = pair(9)
    local helper = state.teams[2]
    wound(of(state, 1, list), 300)
    teams.sweep(state, 1, c)
    teams.sweep(state, 2, c)
    assert(helper.hop and helper.hop.help, 'no help hop')
    state.teams[1].call, state.teams[1].ratio = nil, 0.7
    teams.sweep(state, 2, c)
    assert(not helper.helping and helper.hop and helper.hop.help, 'the old help hop did not run on')
    wound(of(state, 3, list), 300)
    teams.sweep(state, 3, c)
    local call = state.teams[3].call
    assert(call.helper == 2, 'team 2 did not answer the new call')
    teams.sweep(state, 2, c)
    assert(helper.hop.help == 3, 'the helper kept walking to the old call')
    assert(not call.refused, 'the new call was refused')
  end)
end
