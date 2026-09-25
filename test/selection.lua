return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local divisions = require('scripts.divisions')
  local patrol = require('scripts.patrol')
  local barracks = require('scripts.barracks')
  local commands = require('scripts.commands')
  local scout = require('scripts.scout')

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

  local function control()
    dofile('control.lua')
    ctx.players()[1].print = function(message) ctx.players()[1].printed = message end
    return ctx.handlers()
  end

  test('selection: patrols and scouting never start on the selection itself', function()
    divisions.select_area(1, {soldier()})
    assert(patrol.add_waypoint(1, 0, {x = 10, y = 0}, game.surfaces[1]) == nil, 'waypoint added to slot 0')
    assert(patrol.start(1, 0) == nil)
    assert(scout.set(1, 0, true) == nil, 'slot 0 scouted')
    assert(divisions.record(1, 0).mode == 'idle')
  end)

  test('selection: a patrol waypoint on the selection promotes it to the lowest empty division', function()
    local handlers = control()
    local a, b, c = soldier(), soldier(), soldier()
    divisions.assign(1, 1, {c})
    divisions.select_area(1, {a, b})
    handlers.on_lua_shortcut{prototype_name = 'tank-squad-patrol-mode', player_index = 1}
    handlers.on_player_alt_selected_area{item = 'tank-squad-command-tool', player_index = 1,
      area = {left_top = {x = 10, y = 0}, right_bottom = {x = 12, y = 2}}, surface = game.surfaces[1]}
    assert(divisions.selected(1) == 2, 'selection not promoted to division 2')
    local record = divisions.record(1, 2)
    assert(divisions.size(1, 2) == 2 and record.patrol and #record.patrol.waypoints == 1, 'route not on the new division')
    assert(divisions.size(1, 0) == 0, 'promoted soldiers stayed selected')
    local printed = ctx.players()[1].printed
    assert(printed and printed[1] == 'tank-squads.selection-promoted' and printed[2] == 2, 'player not told')
  end)

  test('selection: the scout shortcut promotes the selection; with nine divisions taken it is refused', function()
    local handlers = control()
    divisions.select_area(1, {soldier()})
    handlers.on_lua_shortcut{prototype_name = 'tank-squad-scout-mode', player_index = 1}
    assert(divisions.selected(1) == 1 and divisions.record(1, 1).mode == 'scout', 'scouting not started on division 1')
    for n = 2, 9 do divisions.assign(1, n, {soldier()}) end
    divisions.select_area(1, {soldier()})
    handlers.on_lua_shortcut{prototype_name = 'tank-squad-scout-mode', player_index = 1}
    assert(divisions.selected(1) == 0 and divisions.size(1, 0) == 1, 'selection moved with no free division')
    local printed = ctx.players()[1].printed
    assert(printed and printed[1] == 'tank-squads.selection-no-free-division', 'player not told')
  end)

  test('selection: the selection ring sits outside the division ring', function()
    local a = soldier()
    divisions.assign(1, 4, {a})
    divisions.select_area(1, {a})
    local inner = divisions.record(1, 4).render.rings[a.unit_number]
    local outer = divisions.record(1, 0).render.rings[a.unit_number]
    assert(inner and inner.valid and outer and outer.valid, 'both rings expected')
    assert(outer.args.radius == inner.args.radius + 0.5, 'selection ring radius ' .. outer.args.radius)
  end)

  test('selection: upgrading moves a slot-0 patrol to a free division and unindexes slot 0', function()
    local handlers = control()
    local a, b = soldier(), soldier()
    -- Slot 0 as older versions stored it: an owning division with a route.
    storage.divisions = {[1] = {selected = 0, slots = {[0] = {members = {a.unit_number, b.unit_number}, mode = 'patrol',
      patrol = {waypoints = {{x = 10, y = 0}, {x = 20, y = 0}}, surface_index = 1}, render = {rings = {}, route = {}}}}}}
    storage.unit_divisions = {[a.unit_number] = {player_index = 1, division = 0}, [b.unit_number] = {player_index = 1, division = 0}}
    handlers.configuration_changed()
    local record = divisions.record(1, 1)
    assert(record.mode == 'patrol' and #record.patrol.waypoints == 2 and divisions.size(1, 1) == 2, 'route not moved')
    assert(divisions.record(1, 0).mode == 'idle' and not divisions.record(1, 0).patrol, 'slot 0 kept its job')
    for _, owner in pairs(storage.unit_divisions) do assert(owner.division ~= 0, 'slot 0 still indexed') end
  end)

  test('selection: upgrading ends a slot-0 scout when no division is free', function()
    local handlers = control()
    for n = 1, 9 do divisions.assign(1, n, {soldier()}) end
    local a = soldier()
    storage.divisions[1].slots[0] = {members = {a.unit_number}, mode = 'scout', scout = {}, render = {rings = {}, route = {}}}
    storage.divisions[1].selected = 0
    storage.unit_divisions[a.unit_number] = {player_index = 1, division = 0}
    handlers.configuration_changed()
    assert(divisions.record(1, 0).mode == 'idle' and not divisions.record(1, 0).scout, 'scout kept on slot 0')
    assert(divisions.size(1, 0) == 1, 'soldier left the selection')
    assert(storage.unit_divisions[a.unit_number] == nil, 'slot 0 still indexed')
  end)
end
