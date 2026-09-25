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

  test('add: a selection joins a patrol and every member keeps its orders', function()
    local handlers = control()
    local a, b, c = soldier(), soldier(), soldier()
    local record = route(1, {a, b})
    local walking_a, walking_b = a.command, b.command
    divisions.select_area(1, {c})
    assert(handlers['tank-squad-add-to-division-1'], 'add keybinding not wired')
    handlers['tank-squad-add-to-division-1']{player_index = 1}
    assert(divisions.size(1, 1) == 3, 'the newcomer did not join')
    assert(a.command == walking_a and b.command == walking_b, 'members were sent new orders')
    assert(record.mode == 'patrol' and #record.patrol.waypoints == 2, 'the route changed')
    local post = record.patrol.posts[c.unit_number]
    assert(post and c.command.destination == post.anchor, 'the newcomer got no post')
    assert(divisions.selected(1) == 1 and divisions.size(1, 0) == 0, 'the division was not selected')
  end)

  test('add: a newcomer fighting with no orders still takes up its post', function()
    local handlers = control()
    local a, c = soldier(), soldier()
    local record = route(1, {a})
    storage.combat = {[c.unit_number] = {target = {valid = true}}}
    divisions.select_area(1, {c})
    handlers['tank-squad-add-to-division-1']{player_index = 1}
    local post = record.patrol.posts[c.unit_number]
    assert(post and post.i == 0 and c.command.destination == post.anchor, 'the newcomer waits for a completion that never comes')
  end)

  test('add: starting a patrol still lets a fighting soldier finish its fight', function()
    local a, b = soldier(), soldier()
    local fight = {type = defines.command.attack_area}
    b.command = fight
    storage.combat = {[b.unit_number] = {target = {valid = true}}}
    local record = route(1, {a, b})
    assert(b.command == fight and record.patrol.posts[b.unit_number].i == nil, 'the start interrupted a fight')
  end)

  test('add: a soldier from another division moves over and the rest stay', function()
    local handlers = control()
    local a, b, c = soldier(), soldier(), soldier()
    divisions.assign(1, 1, {a})
    divisions.assign(1, 2, {b, c})
    divisions.select_area(1, {b})
    handlers['tank-squad-add-to-division-1']{player_index = 1}
    assert(divisions.size(1, 1) == 2 and divisions.size(1, 2) == 1, 'wrong rosters after the move')
    assert(select(2, divisions.owner(b.unit_number)) == 1, 'ownership not moved')
    assert(select(2, divisions.owner(c.unit_number)) == 2, 'the old division lost a soldier it kept')
  end)

  test('add: adding a division to itself changes nothing', function()
    local handlers = control()
    local a, b = soldier(), soldier()
    local record = route(1, {a, b})
    local walking, posts = a.command, record.patrol.posts
    divisions.recall(1, 1)
    handlers['tank-squad-add-to-division-1']{player_index = 1}
    assert(divisions.size(1, 1) == 2 and a.command == walking and record.patrol.posts == posts, 'the division was dealt again')
  end)

  test('add: a newcomer to a manual division follows its current order', function()
    local handlers = control()
    local a, c = soldier(), soldier()
    divisions.assign(1, 1, {a})
    local area = {left_top = {x = 50, y = 50}, right_bottom = {x = 60, y = 60}}
    assert(commands.order(1, area, game.surfaces[1]) == 'move')
    local moving = a.command
    divisions.select_area(1, {c})
    handlers['tank-squad-add-to-division-1']{player_index = 1}
    assert(a.command == moving, 'the member was sent again')
    assert(c.command and c.command.destination.x == 55, 'the newcomer did not follow the order')
  end)
end
