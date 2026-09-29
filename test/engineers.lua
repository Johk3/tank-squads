return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local names = require('scripts.names')

  -- The shared harness knows one force and exact-match queries. This adds
  -- an enemy force, the commands and controllers the engineers use, force
  -- lists and ghost_name in queries, and robot coverage as circles.
  local function all()
    local out, i = {}, 1
    while true do
      local e = game.get_entity_by_unit_number(i)
      if not e then break end
      out[#out + 1] = e
      i = i + 1
    end
    return out
  end

  local function force_matches(wanted, e)
    if wanted == nil then return true end
    local list = (type(wanted) == 'table' and wanted[1] ~= nil) and wanted or {wanted}
    for _, f in ipairs(list) do
      if f == e.force then return true end
      if type(f) == 'number' and type(e.force) == 'table' and e.force.index == f then return true end
    end
    return false
  end

  local function one_of(wanted, value)
    if wanted == nil then return true end
    local list = type(wanted) == 'table' and wanted or {wanted}
    for _, v in ipairs(list) do if v == value then return true end end
    return false
  end

  local function engine()
    defines.command.attack, defines.command.stop = 3, 4
    defines.distraction.none = 0
    defines.controllers = {remote = 7}
    prototypes = {entity = {['tank-squad-siege'] = {attack_parameters = {range = 52}}}}
    local player = ctx.players()[1]
    player.surface_index = 1
    player.printed = {}
    player.print = function(message) player.printed[#player.printed + 1] = message end
    player.set_controller = function(args) player.controller = args end
    local own = player.force
    local enemy = {index = 2, name = 'enemy'}
    own.is_enemy = function(other) return other == enemy end
    enemy.is_enemy = function(other) return other == own end
    game.forces = {own, enemy}
    local surface = game.surfaces[1]
    surface.play_sound = function() end
    surface.find_units = function() return {} end
    surface.networks = {}
    surface.find_logistic_networks_by_construction_area = function(position)
      local out = {}
      for _, n in ipairs(surface.networks) do
        local dx, dy = position.x - n.x, position.y - n.y
        if dx * dx + dy * dy <= n.r * n.r then out[#out + 1] = n end
      end
      return out
    end
    surface.find_non_colliding_position = function(_, position) return {x = position.x, y = position.y} end
    surface.create_entity = function(args)
      local e = soldier(args.force, nil, args.position.x, args.position.y)
      e.name, e.type = args.name, 'unit'
      e.health, e.max_health = 800, 800
      e.destroy = function() e.valid = false end
      return e
    end
    surface.find_entities_filtered = function(q)
      local out = {}
      for _, e in ipairs(all()) do
        local ok = e.valid and e.surface == surface and one_of(q.name, e.name) and one_of(q.type, e.type)
          and one_of(q.ghost_name, e.ghost_name) and force_matches(q.force, e)
        if ok and q.radius then
          local dx, dy = e.position.x - q.position.x, e.position.y - q.position.y
          ok = dx * dx + dy * dy <= q.radius * q.radius
        end
        if ok and q.area then
          local a, b = q.area.left_top or q.area[1], q.area.right_bottom or q.area[2]
          local ax, ay, bx, by = a.x or a[1], a.y or a[2], b.x or b[1], b.y or b[2]
          ok = e.position.x >= ax and e.position.x <= bx and e.position.y >= ay and e.position.y <= by
        end
        if ok then out[#out + 1] = e end
        if q.limit and #out >= q.limit then break end
      end
      return out
    end
    return own, enemy, surface
  end

  local function constructor_entity(x, y)
    local own = ctx.players()[1].force
    return game.surfaces[1].create_entity{name = names.constructor, position = {x = x or 0, y = y or 0}, force = own}
  end

  local function ghost(x, y, name)
    local g = soldier(nil, nil, x, y)
    g.name, g.type, g.ghost_name = 'entity-ghost', 'entity-ghost', name or 'stone-wall'
    g.bounding_box = {left_top = {x = x - 0.5, y = y - 0.5}, right_bottom = {x = x + 0.5, y = y + 0.5}}
    g.revive = function()
      g.valid = false
      local w = soldier(nil, nil, x, y)
      w.name, w.type = g.ghost_name, 'wall'
      return {}, w
    end
    return g
  end

  local function enemy_unit(enemy, x, y, name, kind, health)
    local e = soldier(enemy, nil, x, y)
    e.name, e.type = name or 'small-biter', kind or 'unit'
    e.max_health, e.health = health or 100, health or 100
    return e
  end

  ctx.engineers = {engine = engine, constructor_entity = constructor_entity, ghost = ghost, enemy_unit = enemy_unit,
    all = all}

  test('engineers: the constructor stays out of every soldier list', function()
    assert(names.constructor == 'tank-squad-constructor')
    assert(names.constructor_recruit == 'tank-squad-recruit-constructor')
    assert(names.constructor_recipe == 'tank-squad-train-constructor')
    assert(not names.soldier_set[names.constructor] and not names.unit_set[names.constructor])
    assert(not names.recruit_set[names.constructor_recruit])
    assert(#names.recruit_names == 6 and names.unit_names[6] == names.headquarters, 'recruit indices moved')
  end)

  test('engineers: register once, count per force, unregister clears', function()
    engine()
    local constructor = require('scripts.engineers.constructor')
    local e = constructor_entity(5, 5)
    local record = constructor.register(e)
    assert(record and record.id == e.unit_number and record.state == 'seeking')
    assert(constructor.register(e) == record, 'second register made a new record')
    assert(constructor.register(soldier()) == nil, 'a soldier registered as a constructor')
    assert(constructor.count(1) == 1 and constructor.count(2) == 0)
    constructor.unregister(e.unit_number)
    assert(constructor.count(1) == 0)
  end)

  test('engineers: a barracks deploys constructor recruits even with a full quota', function()
    local barracks = require('scripts.barracks')
    local divisions = require('scripts.divisions')
    local b, output = ctx.building()
    engine()
    assert(barracks.configure(b, 1, 2, 1))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    assert(divisions.size(1, 2) == 1, 'soldier did not fill the quota')
    output[names.constructor_recruit] = 1
    barracks.tick()
    assert(output[names.constructor_recruit] == 0, 'constructor recruit stayed in the barracks')
    assert(require('scripts.engineers.constructor').count(1) == 1, 'no constructor deployed')
  end)

  test('engineers: nest score counts worms by size and spawners as two', function()
    local threat = require('scripts.engineers.threat')
    assert(threat.structure{name = 'small-worm-turret', type = 'turret'} == 1)
    assert(threat.structure{name = 'behemoth-worm-turret', type = 'turret'} == 8)
    assert(threat.structure{name = 'biter-spawner', type = 'unit-spawner'} == 2)
    assert(threat.structure{name = 'modded-worm', type = 'turret', max_health = 1000} == 4)
    assert(threat.structure{name = 'tiny-worm', type = 'turret', max_health = 10} == 1)
    local score = threat.nest{{name = 'medium-worm-turret', type = 'turret'},
      {name = 'spitter-spawner', type = 'unit-spawner'}}
    assert(score == 4 and threat.needed(score) == 6)
  end)

  test('engineers: soldier strength by kind and rank', function()
    local threat = require('scripts.engineers.threat')
    assert(threat.strength('tank-squad-soldier-1', 0) == 1)
    assert(threat.strength('tank-squad-siege', 2) == 2.25)
    assert(threat.strength('tank-squad-nuclear', 4) == 6)
    assert(threat.strength('tank-squad-flame', nil) == 1.5)
  end)

  test('engineers: pick takes the nearest until strong enough, else nothing', function()
    local threat = require('scripts.engineers.threat')
    local c = {{id = 1, strength = 1, d = 50}, {id = 2, strength = 3, d = 10}, {id = 3, strength = 1, d = 20},
      {id = 4, strength = 1, d = 20}}
    local picked, total = threat.pick(c, 4)
    assert(#picked == 2 and picked[1].id == 2 and picked[2].id == 3 and total == 4)
    assert(threat.pick(c, 7) == nil, 'picked while short')
    assert(threat.pick(c, 0) == nil, 'picked for no threat')
  end)

  test('engineers: a patrol keeps one soldier per 64 tiles, at least two', function()
    local threat = require('scripts.engineers.threat')
    assert(threat.patrol_keep(0) == 2 and threat.patrol_keep(128) == 2 and threat.patrol_keep(200) == 4)
    local soldiers = {{id = 1, strength = 3}, {id = 2, strength = 1}, {id = 3, strength = 1.5}, {id = 4, strength = 1}}
    local spare = threat.surplus(soldiers, 2)
    assert(#spare == 2 and spare[1].id == 2 and spare[2].id == 4, 'surplus is not the weakest')
    assert(#threat.surplus(soldiers, 4) == 0 and #threat.surplus(soldiers, 9) == 0)
  end)

  test('engineers: loans record, recall and finish', function()
    local loans = require('scripts.engineers.loans')
    assert(not loans.on_loan(7) and loans.finish(7) == nil)
    loans.lend(7, {task_force = 1, player_index = 1, n = 2, back = {x = 1, y = 2}})
    assert(loans.on_loan(7) and loans.get(7).n == 2)
    loans.recall({{valid = true, unit_number = 7}})
    assert(not loans.on_loan(7))
    loans.lend(8, {task_force = 1})
    assert(loans.finish(8).task_force == 1 and not loans.on_loan(8))
  end)
end
