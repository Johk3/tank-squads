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

  -- A barracks on the shredder recipe with a shredder limit.
  local function limited(limit)
    local b, output = building()
    engine()
    b.get_recipe = function() return {name = names.shredder_recipe} end
    assert(barracks.set_shredder_limit(b, 1, limit))
    return b, output
  end

  local function alive()
    local list = {}
    for _, record in pairs(storage.shredders and storage.shredders.units or {}) do list[#list + 1] = record end
    return list
  end

  test('shredders: a barracks pauses at its shredder limit and resumes after a loss', function()
    local b, output = limited(2)
    output[names.shredder_recruit] = 3
    barracks.tick()
    assert(#alive() == 2, #alive() .. ' shredders deployed over a limit of 2')
    assert(output[names.shredder_recruit] == 1, 'the recruit over the limit left the barracks')
    assert(not b.active, 'a barracks at its shredder limit kept training')
    assert(barracks.shredders(b) == 2)
    shredders.unregister(alive()[1].id)
    barracks.tick()
    assert(#alive() == 2 and output[names.shredder_recruit] == 0, 'the lost shredder was not replaced')
    assert(not b.active, 'the replaced shredder did not pause the barracks again')
    shredders.unregister(alive()[1].id)
    barracks.tick()
    assert(b.active, 'a barracks below its shredder limit stayed paused')
  end)

  test('shredders: a spent shredder frees its slot in the limit', function()
    local b, output = limited(1)
    output[names.shredder_recruit] = 1
    barracks.tick()
    assert(not b.active)
    local record = alive()[1]
    assert(shredders.on_trigger{effect_id = shredders.EFFECT, source_entity = record.entity})
    barracks.tick()
    assert(b.active, 'a spent shredder still counted toward the limit')
  end)

  test('shredders: a charging shredder still counts toward the limit', function()
    local _, enemy = engine()
    local b, output = limited(1)
    output[names.shredder_recruit] = 1
    barracks.tick()
    local record = alive()[1]
    local old_id = record.id
    local target = enemy_unit(enemy, 50, 0)
    assert(shredders.charge(record, target, false))
    assert(record.id ~= old_id, 'the charge did not swap the entity')
    output[names.shredder_recruit] = 1
    barracks.tick()
    assert(barracks.shredders(b) == 1 and output[names.shredder_recruit] == 1, 'a charging shredder left the count')
    assert(not b.active)
  end)

  test('shredders: limit 0 trains shredders without a limit', function()
    local b, output = limited(0)
    output[names.shredder_recruit] = 4
    barracks.tick()
    barracks.tick()
    assert(#alive() == 4 and b.active, 'limit 0 held shredders back')
    assert(not barracks.record(b).shredders, 'an unlimited barracks kept a shredder list')
  end)

  test('shredders: a soldier recipe ignores the shredder limit', function()
    local b, output = limited(1)
    output[names.shredder_recruit] = 1
    barracks.tick()
    assert(not b.active)
    b.get_recipe = function() return {name = 'tank-squad-train-1'} end
    barracks.tick()
    assert(b.active, 'a soldier recipe paused on the shredder limit')
  end)

  test('shredders: the shredder limit takes a whole number from 0 to 1000 from the own force', function()
    local b = building()
    assert(barracks.set_shredder_limit(b, 1, 1000))
    assert(barracks.set_shredder_limit(b, 1, 0))
    assert(not barracks.set_shredder_limit(b, 1, -1))
    assert(not barracks.set_shredder_limit(b, 1, 1001))
    assert(not barracks.set_shredder_limit(b, 1, 2.5))
    assert(not barracks.set_shredder_limit(b, 1, nil))
    game.players[2] = {force = {index = 9}}
    assert(not barracks.set_shredder_limit(b, 2, 3), 'another force set the limit')
  end)

  test('shredders: mining a barracks at its limit still deploys its shredder recruits', function()
    local b, output = limited(1)
    output[names.shredder_recruit] = 1
    barracks.tick()
    output[names.shredder_recruit] = 2
    barracks.evacuate(b)
    assert(output[names.shredder_recruit] == 0 and #alive() == 3, 'shredder recruits lost on mining')
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

  test('shredders: a group parks 120 tiles behind its division toward home', function()
    building()
    engine()
    division(1, 200)
    local e, record = shredder(0, 0)
    shredders.tick()
    local group = storage.shredders.groups['1:1']
    assert(group, 'no group for division 1')
    -- Centre (200, 1.5), home (0, 0): 120 tiles toward home is about (80.0, 0.6).
    assert(math.abs(group.point.x - 80) < 0.1 and math.abs(group.point.y - 0.6) < 0.1, 'backline not toward home')
    assert(record.group == '1:1' and e.command.type == defines.command.go_to_location, 'shredder not sent')
    assert(e.command.distraction == defines.distraction.none, 'shredder can be distracted on its way')
  end)

  test('shredders: parked shredders get no new orders until the division moves 30 tiles', function()
    building()
    engine()
    local members = division(1, 200)
    local e, record = shredder(0, 0)
    shredders.tick()
    shredders.on_command_completed(e.unit_number, defines.behavior_result.success)
    assert(record.state == 'parked' and e.command.type == defines.command.stop, 'shredder did not park')
    local calls = commands(e)
    for _ = 1, 5 do game.tick = game.tick + 60; shredders.tick() end
    assert(calls.n == 0, calls.n .. ' orders while parked')
    for _, m in ipairs(members) do m.position = {x = 225, y = m.position.y} end
    game.tick = game.tick + 60
    shredders.tick()
    assert(calls.n == 0, 'a 25-tile move sent the parked shredder')
    for _, m in ipairs(members) do m.position = {x = 240, y = m.position.y} end
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
    local e = game.surfaces[1].create_entity{name = names.shredder, position = {x = 0, y = 0},
      force = ctx.players()[1].force}
    local moon = {index = 2}
    e.surface, e.surface_index = moon, 2
    local record = shredders.register(e)
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

  test('shredders: a parked shredder rams an enemy that hurts it', function()
    local _, enemy = engine()
    local e, record = shredder(0, 0)
    local biter = enemy_unit(enemy, 3, 0, 400)
    assert(shredders.on_damaged{entity = e, cause = biter} == true)
    assert(record.state == 'charging' and record.target == biter, 'no self-defence ram')
    assert(record.entity.command.type == defines.command.attack, 'ram skipped straight to nothing')
  end)

  test('shredders: damage without an enemy cause starts nothing', function()
    engine()
    local e, record = shredder(0, 0)
    assert(shredders.on_damaged{entity = e} == true)
    assert(shredders.on_damaged{entity = e, cause = soldier()} == true)
    assert(record.state == 'moving', 'shredder rammed a friend or nothing')
  end)

  test('shredders: soldier damage stays with the soldier handlers', function()
    engine()
    assert(shredders.on_damaged{entity = soldier()} == false)
  end)

  -- Player 1 standing at the origin with a character, ten biters close by,
  -- one division with three shredders and one with a single shredder.
  local function danger()
    building()
    local own, enemy = engine()
    division(1, 100)
    division(2, -100)
    for i = 1, 4 do shredder(0, i) end
    shredders.tick()
    local groups = storage.shredders.groups
    -- Make the split three and one.
    local moved = table.remove(groups['1:2'].members)
    groups['1:1'].members[#groups['1:1'].members + 1] = moved
    storage.shredders.units[moved].group = '1:1'
    local player = ctx.players()[1]
    player.connected = true
    player.position = {x = 0, y = 0}
    player.character = {valid = true, type = 'character', name = 'character', player = player,
      position = {x = 0, y = 0}, surface = game.surfaces[1]}
    local biters = {}
    for i = 1, 10 do biters[i] = enemy_unit(enemy, 20, i, 15) end
    return player, biters, enemy
  end

  test('shredders: a player in danger gets a shadow from the larger groups only', function()
    local player = danger()
    shredders.watch()
    local shadow = storage.shredders.shadows[1]
    assert(shadow and #shadow.members == 2, 'shadow should take two from the group of three')
    for _, id in ipairs(shadow.members) do
      local r = storage.shredders.units[id]
      assert(r.shadow == 1 and r.group == nil, 'shadow member still in its group')
      assert(r.entity.command.type == defines.command.go_to_location, 'shadow member not sent')
    end
    assert(#storage.shredders.groups['1:1'].members == 1 and #storage.shredders.groups['1:2'].members == 1)
  end)

  test('shredders: a nest nearby is danger too', function()
    local player, biters, enemy = danger()
    for _, b in ipairs(biters) do b.valid = false end
    local nest = enemy_unit(enemy, 45, 0, 350)
    nest.type = 'unit-spawner'
    assert(shredders.danger(game.surfaces[1], player.position, player.force))
    nest.valid = false
    assert(not shredders.danger(game.surfaces[1], player.position, player.force))
  end)

  test('shredders: the rebalance leaves shadow members alone', function()
    danger()
    shredders.watch()
    local shadow = storage.shredders.shadows[1]
    shredders.rebalance()
    for _, id in ipairs(shadow.members) do assert(storage.shredders.units[id].group == nil) end
  end)

  test('shredders: a hurt player sends the shadow once', function()
    local player, biters = danger()
    shredders.watch()
    assert(shredders.on_damaged{entity = player.character, cause = biters[1]} == true)
    local shadow = storage.shredders.shadows[1]
    assert(shadow.spent, 'shadow not spent')
    for _, id in ipairs(shadow.members) do
      assert(storage.shredders.units[id].state == 'igniting', 'shadow member did not strike')
    end
  end)

  -- get_driver() returns a character for a car and may return a LuaPlayer.
  test('shredders: damage to a vehicle a player drives triggers the shadow', function()
    local player, biters = danger()
    shredders.watch()
    local car = {valid = true, type = 'car', name = 'car', position = {x = 0, y = 0}, surface = game.surfaces[1],
      get_driver = function() return player.character end}
    assert(shredders.on_damaged{entity = car, cause = biters[1]} == true)
    assert(storage.shredders.shadows[1].spent, 'vehicle damage ignored')
  end)

  test('shredders: a driver given as LuaPlayer is found too', function()
    local player, biters = danger()
    shredders.watch()
    local spider = {valid = true, type = 'spider-vehicle', name = 'spidertron', position = {x = 0, y = 0},
      surface = game.surfaces[1],
      get_driver = function() return {object_name = 'LuaPlayer', index = 1, force = player.force} end}
    shredders.on_damaged{entity = spider, cause = biters[1]}
    assert(storage.shredders.shadows[1].spent, 'a driver given as LuaPlayer was not found')
  end)

  test('shredders: ten calm seconds release the shadow', function()
    local player, biters = danger()
    shredders.watch()
    local members = storage.shredders.shadows[1].members
    for _, b in ipairs(biters) do b.valid = false end
    shredders.watch()
    game.tick = game.tick + shredders.CALM - 1
    shredders.watch()
    assert(storage.shredders.shadows[1], 'released too early')
    game.tick = game.tick + 1
    shredders.watch()
    assert(storage.shredders.shadows[1] == nil, 'shadow kept after ten calm seconds')
    for _, id in ipairs(members) do assert(storage.shredders.units[id].shadow == nil) end
  end)

  test('shredders: a player without a character loses the shadow', function()
    local player = danger()
    shredders.watch()
    player.character = nil
    shredders.watch()
    assert(storage.shredders.shadows[1] == nil)
  end)

  test('shredders: an unchanged army skips the split without touching its entities', function()
    building()
    engine()
    division(1, 100)
    local e = shredder(0, 0)
    shredders.tick()
    shredders.on_command_completed(e.unit_number, defines.behavior_result.success)
    local reads = ctx.count_reads(e, 'position')
    game.tick = game.tick + 60
    shredders.tick(shredders.REBALANCE_PHASE)
    assert(reads.n == 0, 'the split read ' .. reads.n .. ' positions with nothing changed')
    local f, record = shredder(0, 5)
    game.tick = game.tick + 60
    shredders.tick(shredders.REBALANCE_PHASE)
    assert(record.group == '1:1', 'a new shredder waited for an unrelated change')
  end)

  test('shredders: a split after a change reads positions only of shredders it may move', function()
    building()
    engine()
    division(1, 100)
    local e = shredder(0, 0)
    shredders.tick()
    shredders.on_command_completed(e.unit_number, defines.behavior_result.success)
    local reads = ctx.count_reads(e, 'position')
    -- The fake computes force_index in its metatable; pin it for the counter.
    rawset(e, 'force_index', e.force_index)
    local forces = ctx.count_reads(e, 'force_index')
    local _, record = shredder(0, 5)
    game.tick = game.tick + 60
    shredders.tick(shredders.REBALANCE_PHASE)
    assert(record.group == '1:1', 'new shredder not assigned')
    assert(reads.n == 0 and forces.n == 0, 'the split read a settled shredder ' .. reads.n .. ' + ' .. forces.n .. ' times')
  end)

  -- Review fixes.

  local function moon_surface(found)
    local moon = {index = 2}
    moon.find_entities_filtered = function() return found or {} end
    moon.count_entities_filtered = function() return 0 end
    moon.find_nearest_enemy = function() return nil end
    return moon
  end

  test('shredders: a strike never sends shredders to another surface', function()
    local members, big = battle()
    local ids = {}
    for _, r in ipairs(records()) do ids[#ids + 1] = r.id end
    local moon = moon_surface({big})
    assert(shredders.strike(ids, moon, {x = 0, y = 0}, ctx.players()[1].force, 40) == 0, 'shredders sent across surfaces')
    for _, r in ipairs(records()) do assert(r.state ~= 'igniting') end
  end)

  test('shredders: losses on another surface than the group send nobody', function()
    local members = battle()
    local moon = moon_surface()
    members[1].surface, members[1].surface_index = moon, 2
    members[2].surface, members[2].surface_index = moon, 2
    die(members[1])
    assert(die(members[2]) == 0, 'distress on another surface sent the group')
  end)

  test('shredders: a group keeps its surface while it has a soldier there, and resets on a move', function()
    building()
    engine()
    local members = division(1, 100)
    shredder(0, 0)
    shredders.tick()
    local group = storage.shredders.groups['1:1']
    assert(group.surface_index == 1)
    local moon = moon_surface()
    members[1].surface, members[1].surface_index = moon, 2
    game.tick = game.tick + 60
    shredders.tick()
    assert(group.surface_index == 1, 'group jumped to the surface of its first-listed soldier')
    members[2].surface, members[2].surface_index = moon, 2
    storage.shredders.dirty = false
    game.tick = game.tick + 60
    shredders.update_group(1, 1)
    assert(group.surface_index == 2, 'group stayed on an empty surface')
    assert(storage.shredders.dirty, 'surface change left the split untouched')
  end)

  test('shredders: shadows follow the character, not the remote view', function()
    local player = danger()
    player.position = {x = 5000, y = 0}
    player.surface = moon_surface()
    shredders.watch()
    local shadow = storage.shredders.shadows[1]
    assert(shadow, 'danger at the character ignored while the camera looked away')
    assert(shadow.surface_index == 1 and shadow.point.x * shadow.point.x + shadow.point.y * shadow.point.y < 60 * 60,
      'shadow follows the camera')
  end)

  test('shredders: an unreachable target is skipped, and with none reachable the shredder stands down', function()
    local members, big, small = battle()
    die(members[1]); die(members[2])
    local r
    for _, x in ipairs(records()) do if x.target == big then r = x end end
    shredders.on_command_completed(r.id, 0)
    shredders.on_command_completed(r.id, defines.behavior_result.fail)
    assert(r.target == small, 'retargeted the same unreachable enemy')
    shredders.on_command_completed(r.id, defines.behavior_result.fail)
    assert(r.state == 'parked' and r.entity.name == names.shredder, 'kept charging with nothing reachable')
  end)

  test('shredders: retargets stop after a limit', function()
    building()
    local _, enemy = engine()
    local members = division(1, 100, 1)
    shredder(0, 1)
    shredders.tick()
    for i = 1, 10 do enemy_unit(enemy, 105, i, 400 + i) end
    die(members[1])
    local r = records()[1]
    shredders.on_command_completed(r.id, 0)
    -- RETARGETS new targets, then the next failure gives up.
    for _ = 1, shredders.RETARGETS do
      shredders.on_command_completed(r.id, defines.behavior_result.fail)
      assert(r.state == 'charging', 'gave up before the limit')
    end
    shredders.on_command_completed(r.id, defines.behavior_result.fail)
    assert(r.state == 'parked', 'retargeted without limit')
  end)

  test('shredders: a killing blow does not bring a shredder back', function()
    local _, enemy = engine()
    local e, record = shredder(0, 0)
    local biter = enemy_unit(enemy, 3, 0, 400)
    shredders.on_damaged{entity = e, cause = biter, final_health = 0}
    assert(record.state == 'moving' and record.entity == e, 'dying shredder swapped for a charger')
  end)

  test('shredders: an emptied shadow refills while the danger lasts', function()
    local player = danger()
    shredders.watch()
    local shadow = storage.shredders.shadows[1]
    for _, id in ipairs(shadow.members) do storage.shredders.units[id].shadow = nil end
    shadow.members = {}
    game.tick = game.tick + 60
    shredders.watch()
    local now = storage.shredders.shadows[1]
    assert(now and #now.members > 0, 'player left without a shadow in danger')
  end)

  test('shredders: a self-defence ram does not block the division distress', function()
    local members, big, small, enemy = battle()
    local r = records()[1]
    local biter = enemy_unit(enemy, 1, 1, 15)
    shredders.on_damaged{entity = r.entity, cause = biter, final_health = 500}
    assert(r.state == 'charging')
    die(members[1])
    assert(die(members[2]) == 1, 'one ramming shredder silenced the division')
  end)

  test('shredders: targets killed by others do not use up the retarget limit', function()
    building()
    local _, enemy = engine()
    local members = division(1, 100, 1)
    shredder(0, 1)
    shredders.tick()
    local foes = {}
    for i = 1, 10 do foes[i] = enemy_unit(enemy, 105, i, 400 + i) end
    die(members[1])
    local r = records()[1]
    shredders.on_command_completed(r.id, 0)
    for _ = 1, shredders.RETARGETS + 2 do
      r.target.valid = false
      shredders.on_command_completed(r.id, defines.behavior_result.success)
      assert(r.state == 'charging', 'gave up while enemies were left')
    end
  end)

  test('shredders: a failed swap back strands the shredder until the next slice, not for good', function()
    local members, big, small = battle()
    die(members[1]); die(members[2])
    local r = records()[1]
    big.valid, small.valid = false, false
    local surface = game.surfaces[1]
    local create = surface.create_entity
    surface.create_entity = function() return nil end
    shredders.on_command_completed(r.id, defines.behavior_result.fail)
    assert(r.state == 'stranded' and not r.striking and r.group == nil, 'shredder stuck charging')
    surface.create_entity = create
    game.tick = game.tick + 6
    shredders.tick(1)
    assert(r.entity.name == names.shredder and r.state == 'parked', 'stranded shredder never recovered')
  end)

  test('shredders: a charging shredder found without a charge parks', function()
    engine()
    local e = game.surfaces[1].create_entity{name = names.shredder_charging, position = {x = 0, y = 0},
      force = ctx.players()[1].force}
    local record = shredders.register(e)
    shredders.tick(1)
    assert(record.entity.name == names.shredder and record.state == 'parked', 'invisible charger left posted')
  end)

  test('shredders: shredders of a merged force join the new force', function()
    building()
    engine()
    dofile('control.lua')
    division(1, 100)
    local _, record = shredder(0, 0)
    record.force_index = 7
    shredders.tick()
    assert(record.group == nil, 'shredder of another force joined')
    ctx.handlers()[defines.events.on_forces_merged]{source_index = 7, source_name = 'gone',
      destination = ctx.players()[1].force}
    game.tick = game.tick + 60
    shredders.tick()
    assert(record.group == '1:1', 'merged shredder never joined the new force')
  end)

  local function nest(enemy, x, y)
    local e = enemy_unit(enemy, x, y, 350)
    e.type = 'unit-spawner'
    return e
  end

  -- A shredder charging from the origin at a nest 50 tiles east.
  local function charge_at_nest()
    local _, enemy = engine()
    local _, record = shredder(0, 0)
    local target = nest(enemy, 50, 0)
    assert(shredders.charge(record, target, false))
    assert(record.state == 'charging')
    return record, target, enemy
  end

  test('shredders: a charge stuck on a nest in its way rams that nest', function()
    local record, target, enemy = charge_at_nest()
    local blocker = nest(enemy, 3, 0)
    game.tick = game.tick + shredders.STALL_TICKS - 1
    shredders.tick()
    assert(record.target == target, 'rammed before the charge stalled')
    game.tick = game.tick + 1
    shredders.tick()
    assert(record.target == blocker, 'the stuck charge did not ram the nest in its way')
    assert(record.state == 'charging' and record.entity.command.target == blocker)
    assert(storage.shredders.locks[target.unit_number] == nil, 'the first target stayed locked')
  end)

  test('shredders: a charge on the move is never taken for stuck', function()
    local record, target, enemy = charge_at_nest()
    nest(enemy, 3, 0)
    for i = 1, 20 do
      game.tick = game.tick + 10
      record.entity.position = {x = i * 2, y = 0}
      shredders.tick()
    end
    assert(record.target == target, 'a moving charge changed target')
  end)

  test('shredders: a stuck charge with nothing to ram waits for its path, then gives the target up', function()
    local record, target, enemy = charge_at_nest()
    local other = nest(enemy, 60, 0)
    game.tick = game.tick + shredders.STALL_TICKS
    shredders.tick()
    assert(record.target == target, 'gave up while the path may still come')
    game.tick = game.tick + shredders.STUCK_TICKS
    shredders.tick()
    assert(record.target == other, 'a charge stuck for good kept its target')
    assert(record.unreachable[target.unit_number], 'the stuck target not marked unreachable')
  end)

  test('shredders: a failed path next to a nest rams that nest', function()
    local record, _, enemy = charge_at_nest()
    local blocker = nest(enemy, 2, 2)
    nest(enemy, 55, 0)
    shredders.on_command_completed(record.id, defines.behavior_result.fail)
    assert(record.target == blocker, 'the failed charge did not ram the nest beside it')
  end)

  test('shredders: rams count toward the retarget limit', function()
    local record, _, enemy = charge_at_nest()
    nest(enemy, 3, 0)
    for _ = 1, shredders.RETARGETS + 1 do
      game.tick = game.tick + shredders.STALL_TICKS
      shredders.tick()
    end
    game.tick = game.tick + shredders.STUCK_TICKS
    shredders.tick()
    assert(record.state == 'parked', 'a shredder rammed a nest it cannot reach without end')
    assert(next(storage.shredders.charging) == nil, 'a stood-down shredder is still watched')
  end)

  test('shredders: a crashed shredder leaves the charge watch', function()
    local record = charge_at_nest()
    shredders.on_trigger{effect_id = shredders.EFFECT, source_entity = record.entity}
    shredders.tick()
    assert(next(storage.shredders.charging) == nil)
  end)

  -- A patrolling division of four at x = 200 with two parked shredders and
  -- a swarm of `count` enemy units at x = 230, in a group in `state`.
  local function patrol_swarm(count, state)
    building()
    local _, enemy = engine()
    defines.group_state = {gathering = 0, moving = 1, attacking_distraction = 2, attacking_target = 3,
      finished = 4, pathfinding = 5, wander_in_group = 6}
    local members = division(1, 200, 4)
    divisions.record(1, 1).mode = 'patrol'
    shredder(0, 1)
    shredder(0, 2)
    shredders.tick()
    local group = {state = defines.group_state[state or 'moving']}
    local swarm = {}
    for i = 1, count do
      local e = enemy_unit(enemy, 230 + (i % 5), i % 7, 15)
      e.commandable.parent_group = group
      swarm[i] = e
    end
    return members, swarm, group
  end

  local function charging_count()
    local n = 0
    for _, r in pairs(storage.shredders.units) do
      if r.state == 'igniting' or r.state == 'charging' then n = n + 1 end
    end
    return n
  end

  test('shredders: a patrol that sees a swarm on the move sends one shredder at its middle', function()
    local _, swarm = patrol_swarm(shredders.SWARM_UNITS)
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 1, charging_count() .. ' shredders sent at the swarm')
    local target
    for _, r in pairs(storage.shredders.units) do if r.state == 'igniting' then target = r.target end end
    local middle = require('scripts.shredder_geometry').centre(swarm)
    for _, e in ipairs(swarm) do
      assert(require('scripts.shredder_geometry').distance2(e.position, middle)
        >= require('scripts.shredder_geometry').distance2(target.position, middle), 'target not in the middle')
    end
  end)

  test('shredders: an interception leaves the division free to call a strike', function()
    local members = patrol_swarm(shredders.SWARM_UNITS)
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 1)
    die(members[1]); die(members[2])
    assert(charging_count() == 2, 'the interception blocked the distress strike')
  end)

  test('shredders: a swarm draws one more shredder only after the cooldown', function()
    patrol_swarm(shredders.SWARM_UNITS)
    game.tick = game.tick + 60
    shredders.tick()
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 1, 'a second shredder went within the cooldown')
    game.tick = game.tick + shredders.SWARM_COOLDOWN
    shredders.tick()
    assert(charging_count() == 2, 'no second shredder after the cooldown')
  end)

  test('shredders: small swarms, gathering groups and loose units send nobody', function()
    patrol_swarm(shredders.SWARM_UNITS - 1)
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 0, 'a small swarm drew a shredder')
    patrol_swarm(shredders.SWARM_UNITS, 'gathering')
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 0, 'a gathering group drew a shredder')
    local _, swarm = patrol_swarm(shredders.SWARM_UNITS)
    for _, e in ipairs(swarm) do e.commandable.parent_group = nil end
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 0, 'loose units drew a shredder')
  end)

  test('shredders: a swarm with a few loose units beside it still counts', function()
    local _, swarm = patrol_swarm(shredders.SWARM_UNITS + 4)
    for i = 1, 4 do swarm[i].commandable.parent_group = nil end
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 1, 'loose units hid the swarm')
  end)

  test('shredders: a crowd of loose units is read only until they outnumber the swarm', function()
    local _, swarm = patrol_swarm(40)
    local reads = 0
    for _, e in ipairs(swarm) do
      e.commandable.parent_group = nil
      setmetatable(e.commandable, {__index = function(_, key)
        if key == 'parent_group' then reads = reads + 1 end
      end})
    end
    game.tick = game.tick + 60
    shredders.tick(divisions.phase(1, 1))
    assert(charging_count() == 0)
    assert(reads <= shredders.LOOSE * shredders.SWARM_SCANS, reads .. ' group reads for loose units')
  end)

  test('shredders: only patrolling divisions look out for swarms', function()
    patrol_swarm(shredders.SWARM_UNITS)
    divisions.record(1, 1).mode = 'idle'
    game.tick = game.tick + 60
    shredders.tick()
    assert(charging_count() == 0, 'an idle division intercepted a swarm')
  end)

  test('shredders: a lookout without ready shredders searches nothing', function()
    patrol_swarm(shredders.SWARM_UNITS)
    for _, r in pairs(storage.shredders.units) do r.state = 'stranded' end
    local surface, searches = game.surfaces[1], 0
    local find = surface.find_entities_filtered
    surface.find_entities_filtered = function(query) searches = searches + 1; return find(query) end
    game.tick = game.tick + 60
    shredders.tick(divisions.phase(1, 1))
    assert(searches == 0, searches .. ' searches without a shredder to send')
  end)

  test('shredders: a hurt patrol soldier looks for a swarm around itself', function()
    local members = patrol_swarm(shredders.SWARM_UNITS)
    -- The others are far away: only the hurt soldier sees the swarm.
    members[1].position = {x = 231, y = 2}
    for i = 2, #members do members[i].position = {x = 500, y = i} end
    assert(shredders.patrol_alarm(1, 1, members[1]), 'the hurt soldier drew no shredder')
    assert(charging_count() == 1)
  end)
end
