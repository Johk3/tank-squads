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
end
