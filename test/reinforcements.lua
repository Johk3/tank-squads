return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local divisions = require('scripts.divisions')
  local barracks = require('scripts.barracks')
  local patrol = require('scripts.patrol')
  local commands = require('scripts.commands')

  test('reinforcements append without changing selection and stop at target', function()
    local old = soldier()
    divisions.assign(1, 2, {old})
    divisions.recall(1, 3)
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 3
    barracks.tick()
    assert(divisions.size(1, 2) == 2, 'did not fill exactly the missing slot')
    assert(divisions.selected(1) == 3, 'deployment changed player selection')
    assert(output['tank-squad-recruit-1'] == 2, 'consumed recruits above target')
    assert(b.active == false, 'full division did not pause production')
  end)

  local function headquarters()
    local hq = soldier()
    hq.name = 'tank-squad-headquarters'
    storage.headquarters = storage.headquarters or {}
    storage.headquarters[hq.unit_number] = {entity = hq, force_index = hq.force_index, helpers = {}}
    return hq
  end

  test('a headquarters in the division does not count towards the carrier target', function()
    divisions.assign(1, 2, {headquarters(), soldier()})
    local b, output = building()
    assert(barracks.configure(b, 1, 2, 2))
    output['tank-squad-recruit-1'] = 3
    barracks.tick()
    assert(divisions.size(1, 2) == 3 and output['tank-squad-recruit-1'] == 2, 'the headquarters took a carrier slot')
    assert(b.active == false, 'a full division did not pause production')
    assert(divisions.fighters(1, 2) == 2)
  end)

  test('a barracks training headquarters counts them, so it stops at the target', function()
    divisions.assign(1, 2, {headquarters(), soldier()})
    local b = building()
    b.get_recipe = function() return {name = 'tank-squad-train-headquarters'} end
    assert(barracks.configure(b, 1, 2, 2))
    barracks.tick()
    assert(b.active == false, 'a headquarters barracks kept training past the target')
  end)

  test('linked barracks share one cap and replace a casualty', function()
    local a, first = building()
    local b, second = building()
    assert(barracks.configure(a, 1, 2, 2))
    assert(barracks.configure(b, 1, 2, 2))
    first['tank-squad-recruit-1'], second['tank-squad-recruit-1'] = 3, 3
    barracks.tick()
    assert(divisions.size(1, 2) == 2, 'two producers overshot shared cap')
    divisions.get(1, 2)[1].valid = false
    barracks.tick()
    assert(divisions.size(1, 2) == 2, 'casualty not replaced')
    assert(first['tank-squad-recruit-1'] + second['tank-squad-recruit-1'] == 3)
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
    assert(recruit.command.destination.x == 40, 'replacement did not resume current leg')
  end)

  test('a slower recruit leads the patrol from the next leg; a faster one keeps the lanes', function()
    local reinforcements = require('scripts.reinforcements')
    prototypes = {entity = {['tank-squad-soldier-1'] = {speed = 0.12}, ['tank-squad-flame'] = {speed = 0.07}}}
    local a, c = soldier(nil, nil, 10, 0), soldier(nil, nil, 20, 0)
    divisions.assign(1, 2, {a, c})
    for _, p in ipairs({{x = 0, y = 0}, {x = 100, y = 0}, {x = 100, y = 100}, {x = 0, y = 100}}) do
      patrol.add_waypoint(1, 2, p, a.surface)
    end
    patrol.start(1, 2)
    local r = divisions.record(1, 2).patrol
    local b = building()
    assert(barracks.configure(b, 1, 2, 4))
    local fast = soldier(nil, nil, 50, 50)
    assert(reinforcements.join(barracks.record(b), fast))
    assert(r.lanes, 'a faster recruit discarded the kept lanes')
    local flame = soldier(nil, nil, 50, 50)
    flame.name = 'tank-squad-flame'
    local old = r.leader
    assert(reinforcements.join(barracks.record(b), flame))
    assert(r.leader == old, 'the recruit took over a leg it has not started')
    patrol.advance(old)
    prototypes = nil
    assert(r.leader == flame.unit_number, 'a faster soldier still leads the legs')
    assert(flame.command.destination.x == 100 and flame.command.destination.y == 0, 'leader is not on the route')
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
    assert(divisions.record(1, 4).reinforcement_target == 12)
    assert(barracks.record(b).reinforcement.division == 4)
    gui.click{player_index = 1, element = frame.actions.disable}
    assert(barracks.record(b).reinforcement == nil)
  end)

  test('the panel and barracks window count carriers without the headquarters', function()
    divisions.assign(1, 2, {headquarters(), soldier()})
    local b = building()
    assert(barracks.configure(b, 1, 2, 5))
    local player = game.get_player(1)
    player.gui.relative = ctx.gui_element()
    player.opened = b
    defines.relative_gui_type = {assembling_machine_gui = 1}
    defines.relative_gui_position = {right = 1}
    local gui = require('scripts.barracks_gui')
    gui.open{player_index = 1, entity = b}
    gui.refresh(1)
    local status = player.gui.relative.tank_squads_reinforcements.status.caption
    assert(status[3] == 1 and status[4] == 5, 'barracks window counted the headquarters')
    require('scripts.panel').update(1)
    local caption = player.gui.left.tank_squads_divisions.divisions.division_2.caption
    assert(caption[3][2] == 1 and caption[3][3] == 5, 'panel counted the headquarters')
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
    assert(divisions.record(1, 2).reinforcement_target == nil)
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
end
