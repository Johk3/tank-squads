return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local divisions = require('scripts.divisions')
  local patrol = require('scripts.patrol')
  local barracks = require('scripts.barracks')
  local commands = require('scripts.commands')

  local function route(n, members)
    divisions.assign(1, n, members)
    patrol.add_waypoint(1, n, {x = 10, y = 0}, game.surfaces[1])
    patrol.add_waypoint(1, n, {x = 20, y = 0}, game.surfaces[1])
    patrol.start(1, n)
    return divisions.record(1, n)
  end

  test('selection: selecting a whole patrolling division keeps its route, mode and members', function()
    local a, b = soldier(), soldier()
    local record = route(1, {a, b})
    assert(divisions.select_area(1, {a, b}) == 2)
    assert(record.mode == 'patrol' and record.patrol and #record.patrol.waypoints == 2, 'route lost')
    assert(divisions.size(1, 1) == 2, 'members left the division')
    assert(select(2, divisions.owner(a.unit_number)) == 1, 'the selection took ownership')
    assert(divisions.selected(1) == 0)
  end)

  test('selection: selecting recruits leaves their barracks quota full', function()
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 4
    barracks.tick()
    divisions.select_area(1, divisions.get(1, 2))
    barracks.tick()
    assert(output['tank-squad-recruit-1'] == 2, 'barracks deployed replacements for selected recruits')
    assert(divisions.size(1, 2) == 2)
  end)

  test("selection: a teammate's soldiers are skipped and leave when assigned", function()
    local players = ctx.players()
    players[2] = {index = 2, force = players[1].force, surface = game.surfaces[1]}
    local mine, theirs, loose = soldier(), soldier(), soldier()
    divisions.assign(2, 1, {theirs})
    assert(divisions.select_area(1, {mine, theirs, loose}) == 2, 'teammate soldier selected')
    divisions.assign(2, 3, {loose})
    assert(divisions.size(1, 0) == 1, 'soldier a teammate assigned stayed selected')
    assert(divisions.size(2, 1) == 1, 'teammate division changed')
  end)

  test('selection: a selected division soldier that dies leaves both lists', function()
    local a, b = soldier(), soldier()
    divisions.assign(1, 1, {a, b})
    divisions.select_area(1, {a, b})
    a.valid = false
    assert(divisions.size(1, 1) == 1 and divisions.size(1, 0) == 1)
  end)

  test('selection: an order pulls soldiers out of automated divisions only', function()
    local p1, p2, m1, m2 = soldier(), soldier(), soldier(), soldier()
    local patrolling = route(1, {p1, p2})
    divisions.assign(1, 2, {m1, m2})
    divisions.select_area(1, {p1, m1})
    local area = {left_top = {x = 50, y = 50}, right_bottom = {x = 60, y = 60}}
    assert(commands.order(1, area, game.surfaces[1]) == 'move')
    assert(divisions.size(1, 1) == 1 and divisions.size(1, 2) == 2, 'wrong soldiers left their divisions')
    assert(patrolling.mode == 'patrol' and patrolling.patrol.posts[p2.unit_number], 'the patrol stopped')
    assert(p1.command.destination.x == 55 and m1.command.destination.x == 55, 'selection not ordered')
    assert(divisions.size(1, 0) == 2, 'ordered soldiers left the selection')
  end)
end
