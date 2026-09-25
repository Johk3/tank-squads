return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local divisions = require('scripts.divisions')
  local barracks = require('scripts.barracks')
  local patrol = require('scripts.patrol')
  local commands = require('scripts.commands')

  test('reinforcements append without changing selection and stop at the quota', function()
    local old = soldier()
    divisions.assign(1, 2, {old})
    divisions.recall(1, 3)
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 3
    barracks.tick()
    assert(divisions.size(1, 2) == 3, 'did not add exactly the quota')
    assert(divisions.selected(1) == 3, 'deployment changed player selection')
    assert(output['tank-squad-recruit-1'] == 1, 'consumed recruits above the quota')
    assert(b.active == false, 'a full quota did not pause production')
  end)

  test('soldiers the barracks did not train leave its quota alone', function()
    divisions.assign(1, 2, {soldier(), soldier(), soldier()})
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 2
    barracks.tick()
    assert(divisions.size(1, 2) == 5 and output['tank-squad-recruit-1'] == 0, 'assigned soldiers filled the quota')
  end)

  test('each linked barracks keeps its own quota and replaces its own casualty', function()
    local a, first = building()
    local b, second = building()
    assert(barracks.configure(a, 1, 2, 2))
    assert(barracks.configure(b, 1, 2, 1))
    first['tank-squad-recruit-1'], second['tank-squad-recruit-1'] = 3, 3
    barracks.tick()
    assert(divisions.size(1, 2) == 3, 'the quotas were not added up')
    assert(first['tank-squad-recruit-1'] == 1 and second['tank-squad-recruit-1'] == 2, 'a barracks overshot its quota')
    local from_b = storage.divisions[1].slots[2].reinforcement_sources[b.unit_number].recruits[1]
    game.get_entity_by_unit_number(from_b).valid = false
    barracks.tick()
    assert(divisions.size(1, 2) == 3, 'casualty not replaced')
    assert(first['tank-squad-recruit-1'] == 1 and second['tank-squad-recruit-1'] == 1, 'the wrong barracks replaced the casualty')
  end)

  test('each barracks links to its own division with its own quota', function()
    local a, first = building()
    local b, second = building()
    assert(barracks.configure(a, 1, 2, 3))
    assert(barracks.configure(b, 1, 5, 1))
    first['tank-squad-recruit-1'], second['tank-squad-recruit-1'] = 4, 4
    barracks.tick()
    assert(divisions.size(1, 2) == 3 and divisions.size(1, 5) == 1)
    local reinforcements = require('scripts.reinforcements')
    assert(reinforcements.quota(barracks.record(a)) == 3 and reinforcements.quota(barracks.record(b)) == 1)
  end)

  test('a recruit moved to another division leaves the quota and is replaced', function()
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 1))
    output['tank-squad-recruit-1'] = 2
    barracks.tick()
    local recruit = divisions.get(1, 2)[1]
    divisions.assign(1, 4, {recruit})
    barracks.tick()
    assert(divisions.size(1, 2) == 1 and divisions.get(1, 2)[1] ~= recruit, 'the moved recruit still counted')
    assert(output['tank-squad-recruit-1'] == 0)
  end)

  test('a new target keeps the recruits and a new division starts afresh', function()
    local reinforcements = require('scripts.reinforcements')
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 2
    barracks.tick()
    assert(barracks.configure(b, 1, 2, 3))
    local target, serving = reinforcements.quota(barracks.record(b))
    assert(target == 3 and serving == 2, 'a new target dropped the recruits')
    assert(barracks.configure(b, 1, 6, 3))
    target, serving = reinforcements.quota(barracks.record(b))
    assert(target == 3 and serving == 0, 'recruits followed the barracks to a new division')
    assert(not next(divisions.record(1, 2).reinforcement_sources), 'the old division kept the barracks')
  end)

  test('full linked barracks resolve each member once per sweep and refresh after silent loss', function()
    local members = {}
    for i=1,100 do members[i]=soldier() end
    divisions.assign(1,2,members)
    for i=1,20 do local b=building(); assert(barracks.configure(b,1,2,100)) end
    local get, calls = game.get_entity_by_unit_number, 0
    game.get_entity_by_unit_number = function(id) calls=calls+1; return get(id) end
    barracks.tick()
    assert(calls <= 100, 'full division resolved separately for each producer: '..calls)
    members[1].valid=false
    calls=0
    barracks.tick()
    assert(#divisions.record(1,2).members == 99, 'sweep reused membership from before a silent loss')
    for _, b in ipairs(storage.barracks) do assert(b.entity.active, 'producer did not resume') end
    assert(calls <= 100, 'roster repeatedly revalidated within a sweep')
  end)

  test('reinforcements preserve a wiped patrol and do not interrupt survivors', function()
    local a = soldier()
    divisions.assign(1, 2, {a})
    patrol.add_waypoint(1, 2, {x = 20, y = 0}, a.surface)
    patrol.add_waypoint(1, 2, {x = 40, y = 0}, a.surface)
    patrol.start(1, 2)
    patrol.advance(a.unit_number)
    local calls = 0
    a.commandable.set_command = function() calls = calls + 1 end
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    assert(calls == 0, 'new recruit interrupted existing patrol combat')
    for _, e in ipairs(divisions.get(1, 2)) do e.valid = false end
    divisions.refresh()
    assert(divisions.record(1, 2).patrol, 'wipe deleted reinforced patrol')
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    local recruit = divisions.get(1, 2)[1]
    assert(recruit.command.destination.x == 20, 'replacement did not head for the route')
    patrol.tick()
    local r = divisions.record(1, 2).patrol
    assert(r.posts[recruit.unit_number] and recruit.command.destination == r.posts[recruit.unit_number].anchor,
      'replacement did not take up a post')
  end)

  test('a burst of recruits is dealt posts once, without re-sending the patrol', function()
    local reinforcements = require('scripts.reinforcements')
    local a, c = soldier(nil, nil, 10, 0), soldier(nil, nil, 20, 0)
    divisions.assign(1, 2, {a, c})
    for _, p in ipairs({{x = 0, y = 0}, {x = 100, y = 0}, {x = 100, y = 100}, {x = 0, y = 100}}) do
      patrol.add_waypoint(1, 2, p, a.surface)
    end
    patrol.start(1, 2)
    local r = divisions.record(1, 2).patrol
    local b = building()
    assert(barracks.configure(b, 1, 2, 4))
    local sent = 0
    for _, e in ipairs({a, c}) do e.commandable.set_command = function(command) sent = sent + 1; e.command = command end end
    local first, second = soldier(nil, nil, 50, 50), soldier(nil, nil, 50, 50)
    assert(reinforcements.join(barracks.record(b), first))
    assert(reinforcements.join(barracks.record(b), second))
    assert(r.dirty and not r.posts[first.unit_number], 'posts were dealt once per recruit')
    patrol.tick()
    assert(r.posts[first.unit_number] and r.posts[second.unit_number], 'the recruits got no posts')
    assert(sent == 0, 'the recruits re-sent soldiers walking their legs')
  end)

  test('reinforcements inherit the manual destination', function()
    local a = soldier()
    divisions.assign(1, 2, {a})
    commands.order(1, {left_top = {x = 48, y = 0}, right_bottom = {x = 52, y = 0}}, a.surface)
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    assert(divisions.get(1, 2)[2].command.destination.x == 50)
  end)

  test('blocked reinforcement keeps the recruit and missing slot', function()
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 1))
    output['tank-squad-recruit-1'] = 1
    b.surface.find_non_colliding_position = function() return nil end
    barracks.tick()
    assert(divisions.size(1, 2) == 0 and output['tank-squad-recruit-1'] == 1)
  end)

  test('reinforcement setup rejects invalid owners and limits and supports disabling', function()
    local b = building()
    for _, value in ipairs({-1, 0, 1.5, 1001}) do assert(not barracks.configure(b, 1, 2, value)) end
    assert(not barracks.configure(b, 1, 0, 10))
    assert(not barracks.configure(b, 99, 2, 10))
    local own_force = b.force
    b.force = 'enemy'
    assert(not barracks.configure(b, 1, 2, 10))
    b.force = own_force
    assert(barracks.configure(b, 1, 2, 10))
    assert(barracks.configure(b, 1, nil))
    assert(not next(divisions.record(1, 2).reinforcement_sources))
  end)

  test('barracks GUI applies target and disables reinforcement through real handlers', function()
    local b = building()
    local player = game.get_player(1)
    player.gui.relative = ctx.gui_element()
    player.opened = b
    defines.relative_gui_type = {assembling_machine_gui = 1}
    defines.relative_gui_position = {right = 1}
    local gui = require('scripts.barracks_gui')
    gui.open{player_index = 1, entity = b}
    local frame = player.gui.relative.tank_squads_reinforcements
    assert(frame and frame.valid)
    frame.division.selected_index = 4
    frame.target.text = '12'
    gui.click{player_index = 1, element = frame.actions.apply}
    assert(require('scripts.reinforcements').quota(barracks.record(b)) == 12)
    assert(barracks.record(b).reinforcement.division == 4)
    -- Another barracks opens with its own settings.
    local other = building()
    player.opened = other
    gui.open{player_index = 1, entity = other}
    frame = player.gui.relative.tank_squads_reinforcements
    assert(frame.division.selected_index == 1 and frame.target.text == '10', 'the new barracks showed another barracks\' settings')
    frame.division.selected_index = 4
    frame.target.text = '3'
    gui.click{player_index = 1, element = frame.actions.apply}
    assert(require('scripts.reinforcements').quota(barracks.record(b)) == 12, 'one barracks changed another one\'s quota')
    player.opened = b
    gui.open{player_index = 1, entity = b}
    frame = player.gui.relative.tank_squads_reinforcements
    assert(frame.division.selected_index == 4 and frame.target.text == '12')
    gui.click{player_index = 1, element = frame.actions.disable}
    assert(barracks.record(b).reinforcement == nil)
  end)

  test('the barracks window shows its own quota and the panel adds them up', function()
    divisions.assign(1, 2, {soldier()})
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 5))
    assert(barracks.configure(building(), 1, 2, 4))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    local player = game.get_player(1)
    player.gui.relative = ctx.gui_element()
    player.opened = b
    defines.relative_gui_type = {assembling_machine_gui = 1}
    defines.relative_gui_position = {right = 1}
    local gui = require('scripts.barracks_gui')
    gui.open{player_index = 1, entity = b}
    gui.refresh(1)
    local status = player.gui.relative.tank_squads_reinforcements.status.caption
    assert(status[3] == 1 and status[4] == 5, 'barracks window did not show its own quota')
    require('scripts.panel').update(1)
    local caption = player.gui.screen.tank_squads_divisions.body.divisions.row_2.division_2.caption
    assert(caption[3][2] == 1 and caption[3][3] == 9, 'panel did not add up the quotas')
  end)

  test('reinforcement setup rejects another surface and another player editing a binding', function()
    local b = building()
    local away = soldier(nil, {index = 2})
    divisions.assign(1, 2, {away})
    assert(not barracks.configure(b, 1, 2, 2))
    assert(barracks.configure(b, 1, 3, 2))
    game.players[2] = {force = b.force}
    assert(not barracks.configure(b, 2, 4, 2))
    assert(not barracks.configure(b, 2, nil))
  end)

  test('removing the last producer clears its division binding and resumes ordinary production', function()
    local b = building()
    assert(barracks.configure(b, 1, 2, 1))
    barracks.unregister(b.unit_number)
    assert(not next(divisions.record(1, 2).reinforcement_sources))
    assert(divisions.record(1, 2).reinforcement_surface_index == nil)
  end)

  test('force-change cleanup releases bindings even when barracks now share the new force', function()
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 1))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    assert(not b.active)
    dofile('control.lua')
    ctx.handlers().on_player_changed_force{player_index = 1}
    barracks.tick()
    assert(barracks.record(b).reinforcement == nil, 'orphaned owner binding survived force change')
    assert(b.active, 'orphaned producer remained permanently paused')
  end)

  test('upgrading splits a shared target between barracks and keeps their soldiers', function()
    local reinforcements = require('scripts.reinforcements')
    local hq = soldier()
    hq.name = 'tank-squad-headquarters'
    storage.headquarters = {[hq.unit_number] = {entity = hq, force_index = hq.force_index, helpers = {}}}
    local members = {hq, soldier(), soldier(), soldier()}
    divisions.assign(1, 2, members)
    local a, first = building()
    local c = building()
    c.get_recipe = function() return {name = 'tank-squad-train-headquarters'} end
    local record = divisions.record(1, 2)
    for _, e in ipairs({a, c}) do barracks.record(e).reinforcement = {player_index = 1, division = 2} end
    record.reinforcement_sources = {[a.unit_number] = true, [c.unit_number] = true}
    record.reinforcement_surface_index = 1
    record.reinforcement_target = 5
    reinforcements.upgrade()
    assert(record.reinforcement_target == nil)
    local carrier, command = record.reinforcement_sources[a.unit_number], record.reinforcement_sources[c.unit_number]
    assert(carrier.target == 3 and command.target == 2, 'the shared target was not split')
    assert(#carrier.recruits == 3 and #command.recruits == 1, 'the members were not handed out')
    for _, id in ipairs(carrier.recruits) do assert(id ~= hq.unit_number, 'a carrier barracks took the headquarters') end
    assert(command.recruits[1] == hq.unit_number)
    first['tank-squad-recruit-1'] = 1
    barracks.tick()
    assert(first['tank-squad-recruit-1'] == 1, 'a full carrier barracks trained after the upgrade')
    reinforcements.upgrade()
    assert(record.reinforcement_sources[a.unit_number] == carrier, 'a second upgrade changed the quotas')
  end)
end
