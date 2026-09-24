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
end
