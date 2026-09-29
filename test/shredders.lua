return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local names = require('scripts.names')
  local shredders = require('scripts.shredders')
  local divisions = require('scripts.divisions')
  local barracks = require('scripts.barracks')

  -- The shared harness knows only the commands older modules use, a single
  -- force and a surface whose create_entity makes soldiers. This adds an
  -- enemy force, the stop and attack commands and a create_entity that makes
  -- destroyable units with the requested name.
  local function engine()
    defines.command.attack, defines.command.stop = 3, 4
    defines.distraction.none = 0
    local own = ctx.players()[1].force
    local enemy = {index = 2, name = 'enemy'}
    own.is_enemy = function(other) return other == enemy end
    enemy.is_enemy = function(other) return other == own end
    game.forces = {own, enemy}
    local surface = game.surfaces[1]
    surface.play_sound = function() end
    surface.create_entity = function(args)
      local e = soldier(args.force, nil, args.position.x, args.position.y)
      e.name, e.type = args.name, 'unit'
      e.health, e.max_health = 600, 600
      e.destroy = function() e.valid = false end
      return e
    end
    return own, enemy, surface
  end

  local function shredder(x, y)
    local own = ctx.players()[1].force
    local e = game.surfaces[1].create_entity{name = names.shredder, position = {x = x or 0, y = y or 0}, force = own}
    return e, shredders.register(e)
  end

  local function enemy_unit(enemy, x, y, health)
    local e = soldier(enemy, nil, x, y)
    e.type, e.max_health, e.health = 'unit', health or 400, health or 400
    return e
  end

  test('shredders: register once, unregister clears the record', function()
    engine()
    local e, record = shredder()
    assert(record and record.state == 'moving' and record.entity == e)
    assert(shredders.register(e) == record, 'second register made a new record')
    assert(shredders.register(soldier()) == nil, 'a soldier registered as a shredder')
    shredders.unregister(e.unit_number)
    assert(storage.shredders.units[e.unit_number] == nil)
  end)

  test('shredders: a barracks deploys shredder recruits even with a full quota', function()
    local b, output = building()
    engine()
    assert(barracks.configure(b, 1, 2, 1))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    assert(divisions.size(1, 2) == 1, 'soldier did not fill the quota')
    b.get_recipe = function() return {name = names.shredder_recipe} end
    output[names.shredder_recruit] = 2
    barracks.tick()
    assert(b.active, 'a barracks training shredders paused on a full soldier quota')
    assert(output[names.shredder_recruit] == 0, 'shredder recruits stayed in the barracks')
    local count = 0
    for _, record in pairs(storage.shredders.units) do
      count = count + 1
      assert(record.home_position, 'no rally point remembered')
      assert(record.entity.name == names.shredder)
    end
    assert(count == 2, count .. ' shredders deployed')
    assert(divisions.size(1, 2) == 1, 'a shredder joined the division')
  end)

  test('shredders: a barracks on a soldier recipe still pauses on a full quota', function()
    local b, output = building()
    engine()
    assert(barracks.configure(b, 1, 2, 1))
    output['tank-squad-recruit-1'] = 1
    b.get_recipe = function() return {name = 'tank-squad-train-1'} end
    barracks.tick()
    assert(not b.active, 'full quota no longer pauses soldier training')
  end)

  test('shredders: mining a barracks deploys its shredder recruits', function()
    local b, output = building()
    engine()
    output[names.shredder_recruit] = 1
    barracks.evacuate(b)
    assert(output[names.shredder_recruit] == 0 and next(storage.shredders.units), 'shredder recruit lost on mining')
  end)

  test('shredders: the barracks heals shredders nearby', function()
    building()
    engine()
    local e = shredder(0, 3)
    e.health = 100
    barracks.tick()
    assert(e.health == 120, 'shredder not healed')
  end)

  test('shredders: control registers built shredders and forgets dead ones', function()
    engine()
    dofile('control.lua')
    local e = game.surfaces[1].create_entity{name = names.shredder, position = {x = 0, y = 0}, force = ctx.players()[1].force}
    ctx.handlers()[defines.events.on_built_entity]{entity = e}
    assert(storage.shredders.units[e.unit_number], 'built shredder not registered')
    ctx.handlers()[defines.events.on_entity_died]{entity = e}
    assert(storage.shredders.units[e.unit_number] == nil, 'dead shredder kept')
    local f = game.surfaces[1].create_entity{name = names.shredder, position = {x = 0, y = 0}, force = ctx.players()[1].force}
    shredders.register(f)
    ctx.handlers()[defines.events.script_raised_destroy]{entity = f}
    assert(storage.shredders.units[f.unit_number] == nil, 'destroyed shredder kept')
  end)

  test('shredders: upgrade enables the recipe for researched forces only', function()
    dofile('control.lua')
    local function force(done)
      return {technologies = {['tank-squad-unlock'] = {researched = done}}, recipes = {
        ['tank-squad-train-siege'] = {enabled = false}, ['tank-squad-train-flame'] = {enabled = false},
        [names.shredder_recipe] = {enabled = false}}}
    end
    local researched, pending = force(true), force(false)
    game.forces = {researched, pending}
    ctx.handlers().configuration_changed{}
    assert(researched.recipes[names.shredder_recipe].enabled, 'researched save cannot build shredders')
    assert(not pending.recipes[names.shredder_recipe].enabled, 'upgrade bypasses research')
  end)

  test('shredders: entry points tolerate a save without shredders', function()
    storage.shredders = nil
    assert(shredders.on_soldier_died(soldier()) == 0)
    assert(shredders.on_command_completed(12345, 0) == false)
    assert(shredders.on_trigger{effect_id = 'tank-squad-shredder-impact'} == true)
    assert(shredders.on_trigger{effect_id = 'tank-squad-shot'} == false)
    assert(shredders.on_damaged{entity = soldier()} == false)
    shredders.release(1)
    shredders.tick()
    shredders.tick(3)
  end)

  -- A division of soldiers at x on the player's force, with a barracks at
  -- the origin as its home.
  local function division(n, x, count, player)
    local members = {}
    for i = 1, count or 2 do members[i] = soldier(nil, nil, x, i) end
    divisions.assign(player or 1, n, members)
    return members
  end

  local function commands(e)
    local calls = {n = 0}
    local set = e.commandable.set_command
    e.commandable.set_command = function(command) calls.n = calls.n + 1; set(command) end
    return calls
  end

  test('shredders: a group parks 60 tiles behind its division toward home', function()
    building()
    engine()
    division(1, 100)
    local e, record = shredder(0, 0)
    shredders.tick()
    local group = storage.shredders.groups['1:1']
    assert(group, 'no group for division 1')
    -- Centre (100, 1.5), home (0, 0): 60 tiles toward home is about (40.0, 0.6).
    assert(math.abs(group.point.x - 40) < 0.1 and math.abs(group.point.y - 0.6) < 0.1, 'backline not toward home')
    assert(record.group == '1:1' and e.command.type == defines.command.go_to_location, 'shredder not sent')
    assert(e.command.distraction == defines.distraction.none, 'shredder can be distracted on its way')
  end)

  test('shredders: parked shredders get no new orders until the division moves 20 tiles', function()
    building()
    engine()
    local members = division(1, 100)
    local e, record = shredder(0, 0)
    shredders.tick()
    shredders.on_command_completed(e.unit_number, defines.behavior_result.success)
    assert(record.state == 'parked' and e.command.type == defines.command.stop, 'shredder did not park')
    local calls = commands(e)
    for _ = 1, 5 do game.tick = game.tick + 60; shredders.tick() end
    assert(calls.n == 0, calls.n .. ' orders while parked')
    for _, m in ipairs(members) do m.position = {x = 180, y = m.position.y} end
    game.tick = game.tick + 60
    shredders.tick()
    assert(calls.n == 1 and record.state == 'moving', 'no order after the division moved')
  end)

  test('shredders: shredders split evenly between divisions', function()
    building()
    engine()
    division(1, 100)
    division(2, -100)
    for i = 1, 4 do shredder(0, i) end
    shredders.tick()
    local groups = storage.shredders.groups
    assert(#groups['1:1'].members == 2 and #groups['1:2'].members == 2, 'uneven split')
  end)

  test('shredders: charging shredders stay with their group through a rebalance', function()
    building()
    engine()
    division(1, 100)
    local _, a = shredder(0, 1)
    local _, b = shredder(0, 2)
    shredders.tick()
    a.state = 'charging'
    division(2, -100)
    game.tick = game.tick + 60
    shredders.tick()
    assert(a.group == '1:1', 'a charging shredder was moved')
    assert(b.group == '1:1' or b.group == '1:2')
  end)

  test('shredders: a disbanded division releases its shredders to the rally point', function()
    local b = building()
    engine()
    division(1, 100)
    assert(shredders.deploy(b, {x = 7, y = 8}))
    shredders.tick()
    local _, record = next(storage.shredders.units)
    assert(record.group == '1:1')
    divisions.assign(1, 1, {})
    game.tick = game.tick + 60
    shredders.tick()
    assert(storage.shredders.groups['1:1'] == nil, 'group kept for an empty division')
    assert(record.group == nil and record.entity.command.destination.x == 7, 'shredder did not go to the rally point')
  end)

  test('shredders: a group whose division slot vanished is dropped', function()
    building()
    engine()
    division(1, 100)
    shredder(0, 0)
    shredders.tick()
    storage.divisions[1] = nil
    game.tick = game.tick + 200
    shredders.tick()
    assert(storage.shredders.groups['1:1'] == nil, 'stale group kept')
  end)

  test('shredders: a headquarters-only division gets no shredders', function()
    building()
    engine()
    local hq = soldier(nil, nil, 100, 0)
    hq.name = names.headquarters
    divisions.assign(1, 1, {hq})
    shredder(0, 0)
    shredders.tick()
    assert(storage.shredders.groups['1:1'] == nil, 'unarmed division counted')
  end)

  test('shredders: groups update only in their division phase and split in phase 5', function()
    building()
    engine()
    division(1, 100)
    shredder(0, 0)
    local phase = divisions.phase(1, 1)
    local other = (phase + 1) % divisions.PHASES
    if other == shredders.REBALANCE_PHASE then other = (other + 1) % divisions.PHASES end
    shredders.tick(other)
    assert(storage.shredders.groups['1:1'] == nil, 'group updated outside its phase')
    shredders.tick(phase)
    assert(storage.shredders.groups['1:1'], 'group not updated in its phase')
    shredders.tick(shredders.REBALANCE_PHASE)
    assert(#storage.shredders.groups['1:1'].members == 1, 'no split in the rebalance phase')
  end)

  test('shredders: shredders only serve divisions of their own force', function()
    building()
    engine()
    local rival = {index = 3, name = 'rival', is_enemy = function() return false end}
    game.forces[#game.forces + 1] = rival
    ctx.players()[2] = {index = 2, force = rival, surface = game.surfaces[1], force_index = 3,
      set_shortcut_toggled = function() end}
    local members = {}
    for i = 1, 2 do members[i] = soldier(rival, nil, -100, i) end
    divisions.assign(2, 1, members)
    division(1, 100)
    for i = 1, 2 do shredder(0, i) end
    shredders.tick()
    assert(storage.shredders.groups['2:1'] and #storage.shredders.groups['2:1'].members == 0, 'rival division took shredders')
    assert(#storage.shredders.groups['1:1'].members == 2)
  end)

  test('shredders: a shredder on another surface stays out of the split', function()
    building()
    engine()
    division(1, 100)
    local e, record = shredder(0, 0)
    local moon = {index = 2}
    e.surface, e.surface_index = moon, 2
    shredders.tick()
    assert(record.group == nil and e.command == nil, 'shredder ordered across surfaces')
  end)

  -- A division of four at x = 100 with two grouped shredders, a big enemy
  -- and a small one near the division.
  local function battle()
    building()
    local _, enemy = engine()
    local members = division(1, 100, 4)
    shredder(0, 1)
    shredder(0, 2)
    shredders.tick()
    local big = enemy_unit(enemy, 110, 0, 3000)
    local small = enemy_unit(enemy, 105, 0, 400)
    return members, big, small, enemy
  end

  -- What control.lua does for a dying soldier.
  local function die(e)
    local sent = shredders.on_soldier_died(e)
    divisions.forget(e.unit_number)
    e.valid = false
    return sent
  end

  local function records()
    local out = {}
    for _, r in pairs(storage.shredders.units) do out[#out + 1] = r end
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
  end

  test('shredders: half a division lost within 30 s sends its shredders, strongest first', function()
    local members, big, small = battle()
    assert(die(members[1]) == 0, 'one loss of four sent shredders')
    assert(die(members[2]) == 2, 'half the division lost, no strike')
    local targets = {}
    for _, r in ipairs(records()) do
      assert(r.state == 'igniting' and r.entity.name == names.shredder_charging, 'shredder did not ignite')
      assert(r.entity.command.type == defines.command.stop and r.entity.command.ticks_to_wait == shredders.IGNITION)
      targets[r.target] = true
    end
    assert(targets[big] and targets[small], 'targets not spread')
    assert(storage.shredders.locks[big.unit_number] == 1 and storage.shredders.locks[small.unit_number] == 1)
    assert(#storage.shredders.groups['1:1'].members == 2, 'group lost its charging shredders')
  end)

  test('shredders: more shredders than enemies wrap to the strongest', function()
    building()
    local _, enemy = engine()
    local members = division(1, 100, 1)
    for i = 1, 3 do shredder(0, i) end
    shredders.tick()
    local big = enemy_unit(enemy, 110, 0, 3000)
    enemy_unit(enemy, 105, 0, 400)
    assert(die(members[1]) == 3, 'last soldier lost, not every shredder sent')
    assert(storage.shredders.locks[big.unit_number] == 2, 'extra shredder not on the strongest')
  end)

  test('shredders: losses older than 30 s start a new window', function()
    local members = battle()
    die(members[1])
    game.tick = game.tick + shredders.WINDOW + 1
    assert(die(members[2]) == 0, 'old loss counted')
  end)

  test('shredders: a striking group ignores more distress', function()
    local members = battle()
    die(members[1])
    die(members[2])
    assert(die(members[3]) == 0, 'striking group sent again')
  end)

  test('shredders: no enemy near the distress point sends nobody', function()
    building()
    engine()
    local members = division(1, 100, 1)
    shredder(0, 1)
    shredders.tick()
    assert(die(members[1]) == 0)
    assert(records()[1].state ~= 'igniting')
  end)

  test('shredders: ignition ends in a charge drawn toward the target', function()
    local members = battle()
    die(members[1]); die(members[2])
    local r = records()[1]
    local target = r.target
    shredders.on_command_completed(r.id, defines.behavior_result.success)
    assert(r.state == 'charging', 'no charge after ignition')
    assert(r.entity.command.type == defines.command.attack and r.entity.command.target == target)
    assert(r.entity.command.distraction == defines.distraction.none)
    local body = r.renders.body
    assert(body.valid and body.args.animation == 'tank-squad-shredder-boost' and body.args.orientation_target == target)
    assert(r.renders.lock.valid and r.renders.lock.args.target == target, 'no lock reticle on the target')
  end)

  test('shredders: a target lost during the charge passes to the least locked enemy', function()
    local members, big, _, enemy = battle()
    local medium = enemy_unit(enemy, 108, 3, 300)
    die(members[1]); die(members[2])
    local r
    for _, x in ipairs(records()) do if x.target == big then r = x end end
    shredders.on_command_completed(r.id, 0)
    big.valid = false
    shredders.on_command_completed(r.id, defines.behavior_result.fail)
    assert(r.target == medium, 'retarget did not pick the least locked enemy')
    assert(storage.shredders.locks[big.unit_number] == nil and storage.shredders.locks[medium.unit_number] == 1)
    assert(r.entity.command.type == defines.command.attack and r.entity.command.target == medium)
  end)

  test('shredders: with no enemy left a shredder stands down and rejoins the split', function()
    local members, big, small = battle()
    die(members[1]); die(members[2])
    local r = records()[1]
    big.valid, small.valid = false, false
    shredders.on_command_completed(r.id, defines.behavior_result.fail)
    assert(r.entity.name == names.shredder and r.state == 'parked', 'shredder did not stand down')
    assert(r.group == nil and next(r.renders) == nil, 'stood-down shredder kept its group or drawings')
    shredders.tick()
    assert(r.group == '1:1', 'stood-down shredder not reassigned')
  end)

  test('shredders: the crash draws the breakup and removes the shredder next slice', function()
    local members, big = battle()
    die(members[1]); die(members[2])
    local r
    for _, x in ipairs(records()) do if x.target == big then r = x end end
    shredders.on_command_completed(r.id, 0)
    local entity = r.entity
    assert(shredders.on_trigger{effect_id = shredders.EFFECT, source_entity = entity, target_entity = big,
      target_position = big.position} == true)
    assert(r.state == 'spent' and entity.active == false, 'crashed shredder still active')
    assert(storage.shredders.locks[big.unit_number] == nil, 'lock kept after the crash')
    local breakup
    for _, d in ipairs(ctx.draws()) do if d.args.animation == 'tank-squad-shredder-breakup' then breakup = d end end
    assert(breakup and breakup.args.time_to_live == shredders.BREAKUP_TICKS, 'no breakup drawn')
    assert(not r.renders.body, 'charge drawing kept')
    shredders.tick(1)
    assert(not entity.valid and storage.shredders.units[r.id] == nil, 'crashed shredder not removed')
  end)

  test('shredders: control sends shredders when a division soldier dies', function()
    building()
    local _, enemy = engine()
    dofile('control.lua')
    local members = division(1, 100, 1)
    shredder(0, 1)
    shredders.tick()
    enemy_unit(enemy, 110, 0, 3000)
    ctx.handlers()[defines.events.on_entity_died]{entity = members[1]}
    assert(records()[1].state == 'igniting', 'soldier death did not reach the shredders')
  end)
end
