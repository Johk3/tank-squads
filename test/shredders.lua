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
end
